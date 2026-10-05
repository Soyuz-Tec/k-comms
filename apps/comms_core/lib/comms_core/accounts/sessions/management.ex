defmodule CommsCore.Accounts.Sessions.Management do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{AccessControl, Device, MfaFactor, Session, SessionAuthority, User}
  alias CommsCore.Accounts.Sessions.Persistence
  alias CommsCore.{Administration, Repo}
  alias CommsCore.Security.Password

  def revoke(session_id, user_id, effects) do
    revocation_transaction(fn deadline ->
      lock_revocation_users!(nil, [user_id], deadline)
      SessionAuthority.ensure_budget(deadline)

      session =
        Repo.one(
          from(s in Session,
            where: s.id == ^session_id and s.user_id == ^user_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      SessionAuthority.ensure_budget(deadline)

      session
      |> Session.changeset(%{revoked_at: Persistence.now()})
      |> update_or_rollback()

      effects.revoke_sessions.(session.tenant_id, [session.id], "session_logout")
      SessionAuthority.ensure_budget(deadline)

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def change_password(attrs, subject, effects) when is_map(attrs) and is_map(subject) do
    case change_password_with_effects(attrs, subject, effects) do
      {:ok, result} -> {:ok, result.user}
      {:error, _} = error -> error
    end
  end

  def change_password_with_effects(attrs, subject, effects)
      when is_map(attrs) and is_map(subject) do
    current_password = Persistence.value(attrs, :current_password)
    new_password = Persistence.value(attrs, :new_password)

    with :ok <- validate_password(new_password) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          lock_current_subject!(subject, deadline)
          SessionAuthority.ensure_budget(deadline)

          with :ok <- CommsCore.Accounts.Mfa.require_factor(attrs, subject) do
            user =
              Repo.one(
                from(u in User,
                  where:
                    u.id == ^Persistence.value(subject, :user_id) and
                      u.tenant_id == ^Persistence.value(subject, :tenant_id) and
                      u.status == :active and u.account_type == :human,
                  lock: "FOR NO KEY UPDATE"
                )
              ) || Repo.rollback(:not_found)

            if Password.verify(current_password, user.password_hash) do
              password_hash = Password.hash(new_password)
              recheck_current_subject!(subject, deadline)

              updated =
                user
                |> User.changeset(%{password_hash: password_hash})
                |> update_or_rollback()

              Persistence.invalidate_identity_challenges!(user.tenant_id, user.id)
              revoked_session_ids = revoke_other_sessions!(subject, effects)
              Persistence.insert_audit!(subject, "user.password_change", "user", user.id, %{})
              %{user: updated, revoked_session_ids: revoked_session_ids}
            else
              {:error, :invalid_current_password}
            end
          end
        end,
        timeout: 20_000
      )
      |> proof_transaction_result()
    end
  end

  def step_up(attrs, subject) when is_map(attrs) and is_map(subject) do
    password = Persistence.value(attrs, :current_password)
    deadline = System.monotonic_time(:millisecond) + 15_000

    Repo.transaction(
      fn ->
        lock_current_subject!(subject, deadline)
        SessionAuthority.ensure_budget(deadline)

        with :ok <- CommsCore.Accounts.Mfa.require_factor(attrs, subject) do
          user =
            Repo.one(
              from(u in User,
                where:
                  u.id == ^Persistence.value(subject, :user_id) and
                    u.tenant_id == ^Persistence.value(subject, :tenant_id) and
                    u.status == :active and u.account_type == :human,
                lock: "FOR NO KEY UPDATE"
              )
            ) || Repo.rollback(:not_found)

          if Password.verify(password, user.password_hash) do
            recheck_current_subject!(subject, deadline)

            session =
              Repo.one(
                from(s in Session,
                  where:
                    s.id == ^Persistence.value(subject, :session_id) and s.user_id == ^user.id and
                      s.tenant_id == ^user.tenant_id and is_nil(s.revoked_at) and
                      s.expires_at > ^Persistence.now() and
                      s.absolute_expires_at > ^Persistence.now(),
                  lock: "FOR UPDATE"
                )
              ) || Repo.rollback(:session_expired)

            stepped_up =
              session
              |> Session.changeset(%{step_up_at: Persistence.now()})
              |> update_or_rollback()

            Persistence.insert_audit!(subject, "session.step_up", "session", session.id, %{})
            stepped_up
          else
            {:error, :invalid_current_password}
          end
        end
      end,
      timeout: 20_000
    )
    |> proof_transaction_result()
    |> case do
      {:error, :forbidden} -> classify_step_up_denial(subject)
      result -> result
    end
  end

  defp lock_current_subject!(subject, deadline) do
    case SessionAuthority.lock(subject, deadline) do
      {:ok, _grant} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp recheck_current_subject!(subject, deadline) do
    SessionAuthority.ensure_budget(deadline)

    case AccessControl.access_grant(subject) do
      {:ok, _grant} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Factor verification now belongs to the effect transaction. Returning its
  # error commits failed-attempt/replay state, while skipping the credential or
  # session mutation. Authority failures instead roll the entire transaction back.
  defp proof_transaction_result({:ok, {:error, _} = error}), do: error
  defp proof_transaction_result(result), do: Persistence.transaction_result(result)

  # Preserve the precise expired-own-session result without allowing expired,
  # revoked, foreign or unverified sessions to gain any new authority.
  defp classify_step_up_denial(subject) do
    timestamp = Persistence.now()

    with {:ok, tenant_id} <- Ecto.UUID.cast(Persistence.value(subject, :tenant_id)),
         {:ok, user_id} <- Ecto.UUID.cast(Persistence.value(subject, :user_id)),
         {:ok, device_id} <- Ecto.UUID.cast(Persistence.value(subject, :device_id)),
         {:ok, session_id} <- Ecto.UUID.cast(Persistence.value(subject, :session_id)),
         {:ok, _tenant} <- Administration.active_tenant(tenant_id),
         true <-
           Repo.exists?(
             from(s in Session,
               join: u in User,
               on: u.id == s.user_id and u.tenant_id == s.tenant_id,
               join: d in Device,
               on:
                 d.id == s.device_id and d.user_id == s.user_id and
                   d.tenant_id == s.tenant_id,
               left_join: f in MfaFactor,
               on: f.user_id == u.id and f.tenant_id == u.tenant_id,
               where:
                 s.id == ^session_id and s.user_id == ^user_id and s.device_id == ^device_id and
                   s.tenant_id == ^tenant_id and is_nil(s.revoked_at) and is_nil(d.revoked_at) and
                   u.status == :active and u.account_type == :human and
                   (is_nil(f.enabled_at) or not is_nil(s.mfa_verified_at)) and
                   (s.expires_at <= ^timestamp or s.absolute_expires_at <= ^timestamp)
             )
           ) do
      {:error, :session_expired}
    else
      _ -> {:error, :forbidden}
    end
  end

  def list_devices(subject) do
    Device
    |> where(
      [d],
      d.tenant_id == ^Persistence.value(subject, :tenant_id) and
        d.user_id == ^Persistence.value(subject, :user_id)
    )
    |> order_by([d], desc: d.last_seen_at, desc: d.inserted_at)
    |> Repo.all()
  end

  def list_sessions(subject) do
    Session
    |> where(
      [s],
      s.tenant_id == ^Persistence.value(subject, :tenant_id) and
        s.user_id == ^Persistence.value(subject, :user_id)
    )
    |> order_by([s], desc: s.last_used_at)
    |> preload(user: :platform_role_grant)
    |> Repo.all()
  end

  def revoke_device(device_id, subject, effects) do
    revocation_transaction(fn deadline ->
      lock_revocation_users!(
        Persistence.value(subject, :tenant_id),
        [Persistence.value(subject, :user_id)],
        deadline
      )

      SessionAuthority.ensure_budget(deadline)

      device =
        Repo.one(
          from(d in Device,
            where:
              d.id == ^device_id and
                d.tenant_id == ^Persistence.value(subject, :tenant_id) and
                d.user_id == ^Persistence.value(subject, :user_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      SessionAuthority.ensure_budget(deadline)
      timestamp = Persistence.now()

      device
      |> Device.changeset(%{revoked_at: timestamp})
      |> update_or_rollback()

      session_ids =
        Session
        |> where(
          [s],
          s.tenant_id == ^device.tenant_id and s.user_id == ^device.user_id and
            s.device_id == ^device.id and is_nil(s.revoked_at)
        )
        |> select([s], s.id)
        |> Repo.all()

      SessionAuthority.ensure_budget(deadline)

      Session
      |> where(
        [s],
        s.tenant_id == ^device.tenant_id and s.user_id == ^device.user_id and
          s.device_id == ^device.id and is_nil(s.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: timestamp, updated_at: timestamp])

      effects.notify_device_revoked.(device.tenant_id, device.user_id, device.id)
      effects.revoke_device.(device.tenant_id, device.id, "device_revoked")

      SessionAuthority.ensure_budget(deadline)
      Persistence.insert_audit!(subject, "device.revoke", "device", device.id, %{})
      SessionAuthority.ensure_budget(deadline)
      %{device: device, revoked_session_ids: session_ids}
    end)
    |> Persistence.transaction_result()
  end

  def revoke_own(session_id, subject, effects) do
    revoke_scoped_session(
      session_id,
      Persistence.value(subject, :user_id),
      subject,
      effects
    )
  end

  def list_user_sessions(user_id, subject) do
    with :ok <- AccessControl.authorize_manage_sessions(subject),
         %User{} = actor <- active_actor(subject),
         %User{} = target <-
           Repo.get_by(User,
             id: user_id,
             tenant_id: Persistence.value(subject, :tenant_id),
             account_type: :human
           ),
         :ok <- authorize_session_target(actor, target) do
      {:ok,
       Session
       |> where(
         [s],
         s.tenant_id == ^Persistence.value(subject, :tenant_id) and s.user_id == ^user_id
       )
       |> order_by([s], desc: s.last_used_at)
       |> preload(user: :platform_role_grant)
       |> Repo.all()}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def admin_revoke(user_id, session_id, attrs, subject, effects) when is_map(attrs) do
    with :ok <- AccessControl.authorize_manage_sessions(subject),
         {:ok, reason} <- required_reason(attrs) do
      revocation_transaction(fn deadline ->
        # Audit also references the actor User. Acquire both identities in the
        # same order as Governance before retaining any target Session lock.
        lock_revocation_users!(
          Persistence.value(subject, :tenant_id),
          [Persistence.value(subject, :user_id), user_id],
          deadline
        )

        SessionAuthority.ensure_budget(deadline)

        case AccessControl.authorize_manage_sessions(subject) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        actor = active_actor(subject) || Repo.rollback(:forbidden)

        SessionAuthority.ensure_budget(deadline)

        target =
          Repo.one(
            from(u in User,
              where:
                u.id == ^user_id and
                  u.tenant_id == ^Persistence.value(subject, :tenant_id) and
                  u.account_type == :human
            )
          ) || Repo.rollback(:not_found)

        case authorize_session_target(actor, target) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        SessionAuthority.ensure_budget(deadline)

        session =
          Repo.one(
            from(s in Session,
              where:
                s.id == ^session_id and s.user_id == ^target.id and
                  s.tenant_id == ^target.tenant_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        SessionAuthority.ensure_budget(deadline)

        # The target Session wait may cross the initiating actor's absolute or
        # idle deadline even though both User rows remain fenced.
        case AccessControl.authorize_manage_sessions(subject) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        revoked =
          session
          |> Session.changeset(%{revoked_at: Persistence.now()})
          |> update_or_rollback()

        effects.revoke_sessions.(
          target.tenant_id,
          [revoked.id],
          "session_admin_revoked"
        )

        SessionAuthority.ensure_budget(deadline)

        Persistence.insert_audit!(
          subject,
          "session.admin_revoke",
          "session",
          session.id,
          %{user_id: target.id, reason: reason}
        )

        SessionAuthority.ensure_budget(deadline)
        revoked
      end)
      |> Persistence.transaction_result()
    end
  end

  defp revoke_scoped_session(
         session_id,
         user_id,
         subject,
         effects,
         action \\ "session.revoke"
       ) do
    revocation_transaction(fn deadline ->
      lock_revocation_users!(
        Persistence.value(subject, :tenant_id),
        [Persistence.value(subject, :user_id), user_id],
        deadline
      )

      SessionAuthority.ensure_budget(deadline)

      session =
        Repo.one(
          from(s in Session,
            where:
              s.id == ^session_id and s.user_id == ^user_id and
                s.tenant_id == ^Persistence.value(subject, :tenant_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      SessionAuthority.ensure_budget(deadline)
      timestamp = Persistence.now()

      session
      |> Session.changeset(%{revoked_at: timestamp})
      |> update_or_rollback()

      effects.revoke_sessions.(session.tenant_id, [session.id], "session_revoked")

      SessionAuthority.ensure_budget(deadline)

      Persistence.insert_audit!(
        subject,
        action,
        "session",
        session.id,
        %{user_id: user_id}
      )

      SessionAuthority.ensure_budget(deadline)
      session
    end)
    |> Persistence.transaction_result()
  end

  # Revocation is also used for cleanup after suspension or anonymization. It
  # therefore locks the owning identities without requiring active authority.
  # User-before-Device/Session prevents later Audit FK checks from introducing
  # the inverse edge against SessionAuthority; multiple Users are sorted to
  # agree with Governance and mutually crossed administrator revocations.
  # NO KEY UPDATE still fences identity mutations and SessionAuthority UPDATE,
  # but permits Audit's KEY SHARE references while a tenant-settings writer
  # retains Tenant UPDATE. Revocation never changes User identity key columns.
  defp lock_revocation_users!(tenant_id, user_ids, deadline) do
    ids = Enum.uniq(user_ids) |> Enum.sort()
    SessionAuthority.ensure_budget(deadline)

    query = from(user in User, where: user.id in ^ids, order_by: [asc: user.id])

    query =
      if tenant_id,
        do: where(query, [user], user.tenant_id == ^tenant_id),
        else: query

    users = Repo.all(from(user in query, select: user.id, lock: "FOR NO KEY UPDATE"))
    SessionAuthority.ensure_budget(deadline)
    if length(users) != length(ids), do: Repo.rollback(:not_found)
    :ok
  end

  defp revocation_transaction(operation) do
    deadline = System.monotonic_time(:millisecond) + 15_000
    Repo.transaction(fn -> operation.(deadline) end, timeout: 20_000)
  end

  defp revoke_other_sessions!(subject, effects) do
    query =
      Session
      |> where(
        [s],
        s.tenant_id == ^Persistence.value(subject, :tenant_id) and
          s.user_id == ^Persistence.value(subject, :user_id) and
          s.id != ^Persistence.value(subject, :session_id) and is_nil(s.revoked_at)
      )

    ids = query |> select([s], s.id) |> Repo.all()
    Repo.update_all(query, set: [revoked_at: Persistence.now(), updated_at: Persistence.now()])

    effects.revoke_sessions.(
      Persistence.value(subject, :tenant_id),
      ids,
      "password_changed"
    )

    ids
  end

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp active_actor(subject) do
    Repo.get_by(User,
      id: Persistence.value(subject, :user_id),
      tenant_id: Persistence.value(subject, :tenant_id),
      status: :active,
      account_type: :human,
      access_scope: :workspace
    )
  end

  defp authorize_session_target(%User{role: :owner}, _target), do: :ok

  defp authorize_session_target(
         %User{role: :security_admin},
         %User{role: role}
       )
       when role not in [:owner, :security_admin],
       do: :ok

  defp authorize_session_target(_, _), do: {:error, :forbidden}

  defp required_reason(attrs) do
    case Persistence.value(attrs, :reason) do
      reason when is_binary(reason) ->
        normalized = String.trim(reason)

        if String.length(normalized) in 3..1_000,
          do: {:ok, normalized},
          else: {:error, :reason_required}

      _ ->
        {:error, :reason_required}
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
