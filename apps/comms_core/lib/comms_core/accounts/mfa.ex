defmodule CommsCore.Accounts.Mfa do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessControl,
    AuthChallenge,
    IdentitySecretBox,
    MfaFactor,
    MfaFactorState,
    Projector,
    Session,
    SessionAuthority,
    User
  }

  alias CommsCore.Accounts.Sessions.{Authentication, Persistence, RefreshTokens}
  alias CommsCore.Repo

  @challenge_seconds 300
  @maximum_attempts 5

  defdelegate enabled?(user_id, tenant_id), to: MfaFactorState

  def security(subject) do
    with {:ok, grant} <- AccessControl.access_grant(subject) do
      factor = Repo.get_by(MfaFactor, user_id: grant.user_id, tenant_id: grant.tenant_id)

      {:ok,
       %{
         mfa_enabled: factor != nil and factor.enabled_at != nil,
         recovery_codes_remaining: if(factor, do: length(factor.recovery_hashes), else: 0),
         authentication_method: Repo.get!(Session, grant.session_id).authentication_method
       }}
    end
  end

  def password_sign_in(tenant_slug, email, password, device_attrs) do
    with {:ok, %{user: user, tenant: tenant}} <-
           Authentication.verify_identity(tenant_slug, email, password) do
      verified_password_hash = user.password_hash
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          tenant =
            case SessionAuthority.lock_active_tenant(tenant.id, deadline) do
              {:ok, current} -> current
              {:error, _} -> Repo.rollback(:invalid_credentials)
            end

          SessionAuthority.ensure_budget(deadline)

          user =
            Repo.one(
              from(u in User,
                where:
                  u.id == ^user.id and u.tenant_id == ^user.tenant_id and u.status == :active and
                    u.account_type == :human,
                lock: "FOR UPDATE"
              )
            ) || Repo.rollback(:invalid_credentials)

          if user.password_hash != verified_password_hash, do: Repo.rollback(:invalid_credentials)
          SessionAuthority.ensure_budget(deadline)

          if enabled?(user.id, user.tenant_id) do
            token = random_token()

            challenge = %AuthChallenge{
              tenant_id: user.tenant_id,
              user_id: user.id,
              kind: "mfa_login",
              token_hash: digest(token),
              payload: %{
                device: Map.take(device_attrs, ["id", "name", "platform", :id, :name, :platform])
              },
              expires_at: DateTime.add(Persistence.now(), @challenge_seconds)
            }

            with {:ok, _} <- Repo.insert(challenge) do
              {:ok, %{mfa_required: true, challenge_token: token, expires_in: @challenge_seconds}}
            end
          else
            create_authentication(user, tenant, device_attrs, false, fn ->
              SessionAuthority.ensure_budget(deadline)
            end)
          end
        end,
        timeout: 20_000
      )
      |> flatten()
    end
  end

  def complete_sign_in(token, code, _attrs) when is_binary(token) and byte_size(token) <= 256 do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Repo.transaction(
      fn ->
        SessionAuthority.ensure_budget(deadline)

        hint =
          Repo.one(
            from(c in AuthChallenge,
              where: c.token_hash == ^digest(token) and c.kind == "mfa_login"
            )
          )

        with %AuthChallenge{} <- hint,
             {:ok, tenant} <- SessionAuthority.lock_active_tenant(hint.tenant_id, deadline) do
          SessionAuthority.ensure_budget(deadline)

          user =
            Repo.one(
              from(u in User,
                where:
                  u.id == ^hint.user_id and u.tenant_id == ^hint.tenant_id and u.status == :active and
                    u.account_type == :human,
                lock: "FOR UPDATE"
              )
            )

          SessionAuthority.ensure_budget(deadline)

          challenge =
            Repo.one(
              from(c in AuthChallenge,
                where:
                  c.id == ^hint.id and c.tenant_id == ^hint.tenant_id and
                    c.user_id == ^hint.user_id and
                    c.token_hash == ^digest(token) and c.kind == "mfa_login",
                lock: "FOR UPDATE"
              )
            )

          with :ok <- current_challenge(challenge, user) do
            SessionAuthority.ensure_budget(deadline)
            factor = locked_factor(user.id, user.tenant_id)
            SessionAuthority.ensure_budget(deadline)

            # Factor acquisition can wait past the challenge lifetime too.
            with :ok <- current_challenge(challenge, user) do
              challenge =
                Repo.update!(
                  Ecto.Changeset.change(%AuthChallenge{} = challenge,
                    attempts: challenge.attempts + 1
                  )
                )

              with :ok <- verify_enabled_factor(factor, code) do
                create_authentication(
                  user,
                  tenant,
                  Map.get(challenge.payload, "device", %{}),
                  true,
                  fn ->
                    # Device preparation can itself wait. Recheck the exact owned
                    # challenge just before minting; late expiry rolls preparation
                    # and successful proof back, without publishing a new device.
                    SessionAuthority.ensure_budget(deadline)
                    current = Repo.get!(AuthChallenge, challenge.id)

                    unless current.id == challenge.id and current.tenant_id == user.tenant_id and
                             current.user_id == user.id and current.kind == "mfa_login" and
                             current.token_hash == digest(token) and
                             current.attempts == challenge.attempts and
                             current.attempts <= @maximum_attempts and is_nil(current.consumed_at) and
                             DateTime.compare(current.expires_at, Persistence.now()) == :gt,
                           do: Repo.rollback(:invalid_mfa_challenge)

                    Repo.update!(Ecto.Changeset.change(current, consumed_at: Persistence.now()))
                    :ok
                  end
                )
              end
            end
          end
        else
          _ -> {:error, :invalid_mfa_challenge}
        end
      end,
      timeout: 20_000
    )
    |> flatten()
  end

  def complete_sign_in(_, _, _), do: {:error, :invalid_mfa_challenge}

  def enroll(subject) do
    privileged_transaction(subject, fn grant, deadline ->
      user = Repo.get_by!(User, id: grant.user_id, tenant_id: grant.tenant_id)

      factor = current_factor(grant, subject, deadline)
      if factor && factor.enabled_at, do: Repo.rollback(:mfa_already_enabled)
      SessionAuthority.ensure_budget(deadline)
      if factor, do: Repo.delete!(%MfaFactor{} = factor)
      id = Ecto.UUID.generate()
      secret = NimbleTOTP.secret()

      encrypted =
        case IdentitySecretBox.encrypt(secret, box_context(user.tenant_id, id)) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end

      Repo.insert!(
        struct!(
          MfaFactor,
          Map.merge(encrypted, %{id: id, user_id: user.id, tenant_id: user.tenant_id})
        )
      )

      Persistence.insert_audit!(
        subject,
        "identity.mfa_enrollment_started",
        "user",
        user.id,
        %{}
      )

      label = URI.encode_www_form("K-Comms:" <> user.email)

      {:ok,
       %{
         secret: Base.encode32(secret, padding: false),
         provisioning_uri:
           "otpauth://totp/#{label}?secret=#{Base.encode32(secret, padding: false)}&issuer=K-Comms&algorithm=SHA1&digits=6&period=30"
       }}
    end)
  end

  def confirm(code, subject, effects) do
    privileged_transaction(subject, fn grant, deadline ->
      factor = current_factor(grant, subject, deadline)

      cond do
        is_nil(factor) ->
          {:error, :mfa_enrollment_required}

        factor.enabled_at != nil ->
          {:error, :mfa_already_enabled}

        DateTime.diff(Persistence.now(), factor.inserted_at) > 600 ->
          {:error, :mfa_enrollment_expired}

        true ->
          with :ok <- verify_factor(factor, code, false) do
            SessionAuthority.ensure_budget(deadline)
            current_privileged!(subject)
            codes = recovery_codes()
            %MfaFactor{} = factor = Repo.get!(MfaFactor, factor.id)

            Repo.update!(
              Ecto.Changeset.change(%MfaFactor{} = factor,
                enabled_at: Persistence.now(),
                recovery_hashes: Enum.map(codes, &digest/1)
              )
            )

            ids = revoke_other_sessions(subject, effects, "mfa_enabled")
            mark_current_verified(subject)

            Persistence.insert_audit!(
              subject,
              "identity.mfa_enabled",
              "user",
              grant.user_id,
              %{}
            )

            {:ok, %{recovery_codes: codes, revoked_session_ids: ids}}
          end
      end
    end)
  end

  def disable(code, subject, effects) do
    privileged_transaction(subject, fn grant, deadline ->
      factor = current_factor(grant, subject, deadline)

      with :ok <- verify_enabled_factor(factor, code) do
        SessionAuthority.ensure_budget(deadline)
        current_privileged!(subject)
        Repo.delete!(factor)
        ids = revoke_other_sessions(subject, effects, "mfa_disabled")
        Persistence.insert_audit!(subject, "identity.mfa_disabled", "user", grant.user_id, %{})
        {:ok, %{revoked_session_ids: ids}}
      end
    end)
  end

  def rotate_recovery(code, subject, effects) do
    privileged_transaction(subject, fn grant, deadline ->
      factor = current_factor(grant, subject, deadline)

      with :ok <- verify_enabled_factor(factor, code) do
        SessionAuthority.ensure_budget(deadline)
        current_privileged!(subject)
        codes = recovery_codes()
        factor = Repo.get!(MfaFactor, factor.id)

        Repo.update!(
          Ecto.Changeset.change(%MfaFactor{} = factor,
            recovery_hashes: Enum.map(codes, &digest/1)
          )
        )

        ids = revoke_other_sessions(subject, effects, "mfa_recovery_rotated")

        Persistence.insert_audit!(
          subject,
          "identity.mfa_recovery_rotated",
          "user",
          grant.user_id,
          %{}
        )

        {:ok, %{recovery_codes: codes, revoked_session_ids: ids}}
      end
    end)
  end

  # Owns a committing transaction for standalone proof checks. Nested calls
  # remain inside the caller's authority/effect transaction; callers return a
  # proof error to commit rate/replay state while skipping their sensitive effect.
  def verify(user_id, tenant_id, code) do
    Repo.transaction(fn -> verify_locked(user_id, tenant_id, code) end) |> flatten()
  end

  def require_factor(attrs, subject) do
    with {:ok, %{account_type: :human} = grant} <- AccessControl.access_grant(subject) do
      if enabled?(grant.user_id, grant.tenant_id),
        do: verify(grant.user_id, grant.tenant_id, Persistence.value(attrs, :mfa_code)),
        else: :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp verify_locked(user_id, tenant_id, code) do
    case locked_factor(user_id, tenant_id) do
      %MfaFactor{enabled_at: enabled_at} = factor when not is_nil(enabled_at) ->
        verify_factor(factor, code, true)

      _ ->
        {:error, :mfa_enrollment_required}
    end
  end

  defp verify_factor(%MfaFactor{} = factor, code, allow_recovery) do
    timestamp = Persistence.now()

    cond do
      factor.locked_until && DateTime.compare(factor.locked_until, timestamp) == :gt ->
        {:error, :mfa_rate_limited}

      not is_binary(code) or byte_size(code) > 128 ->
        failure(factor)

      true ->
        recovery_hash = digest(String.trim(code))

        recovery =
          allow_recovery and Enum.any?(factor.recovery_hashes, &constant_equal(&1, recovery_hash))

        with {:ok, secret} <-
               IdentitySecretBox.decrypt(
                 Map.from_struct(factor),
                 box_context(factor.tenant_id, factor.id)
               ) do
          step = div(DateTime.to_unix(timestamp), 30)

          valid_step =
            Enum.find([step, step - 1], fn candidate ->
              candidate > factor.last_used_step and
                NimbleTOTP.valid?(secret, code, time: candidate * 30)
            end)

          cond do
            recovery ->
              Repo.update!(
                Ecto.Changeset.change(%MfaFactor{} = factor,
                  recovery_hashes:
                    Enum.reject(factor.recovery_hashes, &constant_equal(&1, recovery_hash)),
                  failed_attempts: 0,
                  locked_until: nil
                )
              )

              :ok

            valid_step ->
              Repo.update!(
                Ecto.Changeset.change(%MfaFactor{} = factor,
                  last_used_step: valid_step,
                  failed_attempts: 0,
                  locked_until: nil
                )
              )

              :ok

            true ->
              failure(factor)
          end
        end
    end
  end

  defp failure(factor) do
    attempts = factor.failed_attempts + 1

    locked_until =
      if attempts >= @maximum_attempts, do: DateTime.add(Persistence.now(), 300), else: nil

    Repo.update!(
      Ecto.Changeset.change(%MfaFactor{} = factor,
        failed_attempts: if(locked_until, do: 0, else: attempts),
        locked_until: locked_until
      )
    )

    {:error, :invalid_mfa_code}
  end

  defp current_challenge(%AuthChallenge{} = challenge, %User{} = user) do
    cond do
      challenge.tenant_id != user.tenant_id or challenge.user_id != user.id or
        challenge.kind != "mfa_login" or not is_nil(challenge.consumed_at) or
          DateTime.compare(challenge.expires_at, Persistence.now()) != :gt ->
        {:error, :invalid_mfa_challenge}

      challenge.attempts >= @maximum_attempts ->
        {:error, :mfa_rate_limited}

      true ->
        :ok
    end
  end

  defp current_challenge(_, _), do: {:error, :invalid_mfa_challenge}

  defp create_authentication(user, tenant, attrs, verified, before_mint) do
    with {:ok, device} <- Persistence.upsert_device(user, attrs),
         :ok <- before_mint.(),
         {:ok, %Session{} = session, refresh_token} <- RefreshTokens.create(user, device) do
      session =
        if verified do
          Repo.update!(
            Ecto.Changeset.change(%Session{} = session, mfa_verified_at: Persistence.now())
          )
        else
          session
        end

      {:ok,
       Projector.authentication(%{
         user: user,
         tenant: tenant,
         device: device,
         session: session,
         refresh_token: refresh_token
       })}
    end
  end

  defp privileged(subject) do
    with {:ok, %{account_type: :human} = grant} <- AccessControl.access_grant(subject),
         true <- grant.step_up_recent? do
      {:ok, grant}
    else
      false -> {:error, :step_up_required}
      _ -> {:error, :forbidden}
    end
  end

  defp privileged_transaction(subject, operation) do
    with {:ok, _grant} <- privileged(subject) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          case SessionAuthority.lock(subject, deadline) do
            {:ok, _grant} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          grant = current_privileged!(subject)
          operation.(grant, deadline)
        end,
        timeout: 20_000
      )
      |> flatten()
    end
  end

  defp current_privileged!(subject) do
    case privileged(subject) do
      {:ok, grant} -> grant
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp current_factor(grant, subject, deadline) do
    SessionAuthority.ensure_budget(deadline)
    factor = locked_factor(grant.user_id, grant.tenant_id)
    # Waiting for a factor must not reuse an authority/step-up deadline checked
    # before that wait. The User/device/session locks still fence revocation.
    SessionAuthority.ensure_budget(deadline)
    current_privileged!(subject)
    factor
  end

  defp verify_enabled_factor(%MfaFactor{enabled_at: enabled_at} = factor, code)
       when not is_nil(enabled_at),
       do: verify_factor(factor, code, true)

  defp verify_enabled_factor(_, _), do: {:error, :mfa_enrollment_required}

  defp revoke_other_sessions(subject, effects, reason) do
    Persistence.invalidate_identity_challenges!(
      Persistence.value(subject, :tenant_id),
      Persistence.value(subject, :user_id)
    )

    query =
      from(s in Session,
        where:
          s.tenant_id == ^Persistence.value(subject, :tenant_id) and
            s.user_id == ^Persistence.value(subject, :user_id) and
            s.id != ^Persistence.value(subject, :session_id) and is_nil(s.revoked_at)
      )

    ids = Repo.all(from(s in query, select: s.id))
    Repo.update_all(query, set: [revoked_at: Persistence.now(), updated_at: Persistence.now()])
    effects.revoke_sessions.(Persistence.value(subject, :tenant_id), ids, reason)
    ids
  end

  defp mark_current_verified(subject) do
    Repo.update_all(
      from(s in Session,
        where:
          s.id == ^Persistence.value(subject, :session_id) and
            s.tenant_id == ^Persistence.value(subject, :tenant_id) and
            s.user_id == ^Persistence.value(subject, :user_id)
      ),
      set: [mfa_verified_at: Persistence.now()]
    )
  end

  defp locked_factor(user_id, tenant_id),
    do:
      Repo.one(
        from(f in MfaFactor,
          where: f.user_id == ^user_id and f.tenant_id == ^tenant_id,
          lock: "FOR UPDATE"
        )
      )

  defp recovery_codes, do: for(_ <- 1..10, do: random_token())
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)
  defp constant_equal(a, b), do: byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  defp box_context(tenant_id, id), do: %{tenant_id: tenant_id, identity_secret_id: id, version: 1}
  defp flatten({:ok, result}), do: result
  defp flatten({:error, _} = error), do: error
end
