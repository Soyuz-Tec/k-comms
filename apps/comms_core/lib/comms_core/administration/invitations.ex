defmodule CommsCore.Administration.Invitations do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts
  alias CommsCore.Accounts.InvitedUserCommand
  alias CommsCore.Administration
  alias CommsCore.Administration.{Invitation, Projector}
  alias CommsCore.Audit
  alias CommsCore.{AdmissionQuotas, Repo}

  @token_bytes 32
  @invitation_roles [:member, :moderator, :admin, :compliance_admin, :security_admin]
  @invitation_statuses [:pending, :accepted, :revoked, :expired]

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    email = attrs |> value(:email) |> to_string() |> String.trim() |> String.downcase()
    idempotency_key = value(attrs, :idempotency_key)

    with {:ok, role} <- requested_role(attrs),
         :ok <- Administration.authorize_manage_invitations(subject),
         :ok <- Accounts.authorize_invitation_identity(subject, email, role),
         :ok <- expire_pending(tenant_id, email) do
      case existing_idempotent(tenant_id, idempotency_key) do
        %Invitation{} = invitation ->
          {:ok, %{invitation: Projector.invitation(invitation), token: nil, replayed: true}}

        nil ->
          insert(attrs, subject, email, role, idempotency_key)
      end
    end
  end

  def list(subject, status) when is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- Administration.authorize_administer_tenant(subject),
         :ok <- expire_pending(tenant_id) do
      invitations =
        Invitation
        |> where([invitation], invitation.tenant_id == ^tenant_id)
        |> maybe_filter_status(status)
        |> order_by([invitation], desc: invitation.inserted_at)
        |> Repo.all()
        |> Enum.map(&Projector.invitation/1)

      {:ok, invitations}
    end
  end

  def revoke(id, attrs, subject)
      when is_binary(id) and is_map(attrs) and is_map(subject) do
    with :ok <- Administration.authorize_manage_invitations(subject),
         {:ok, reason} <- required_reason(attrs),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        invitation =
          Repo.one(
            from(invitation in Invitation,
              where:
                invitation.id == ^id and
                  invitation.tenant_id == ^value(subject, :tenant_id),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if invitation.lock_version != expected_version, do: Repo.rollback(:stale_version)
        if invitation.status != :pending, do: Repo.rollback(:invitation_not_pending)

        updated =
          invitation
          |> Invitation.changeset(%{status: :revoked, revoked_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        audit_or_rollback(
          Audit.record(%{
            tenant_id: invitation.tenant_id,
            actor_user_id: value(subject, :user_id),
            action: "invitation.revoke",
            resource_type: "invitation",
            resource_id: invitation.id,
            metadata: %{email: invitation.email, reason: reason},
            request_id: value(subject, :request_id)
          })
        )

        Projector.invitation(updated)
      end)
      |> transaction_result()
    end
  end

  def accept(attrs) when is_map(attrs) do
    password = value(attrs, :password)

    with :ok <- Accounts.validate_invitation_password(password),
         {:ok, invitation_id, secret} <- parse_one_time_token(value(attrs, :token)) do
      case Repo.transaction(fn ->
             accept_locked(invitation_id, secret, password, value(attrs, :display_name))
           end) do
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, user_view} -> {:ok, user_view}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp insert(_attrs, subject, email, role, idempotency_key) do
    tenant_id = value(subject, :tenant_id)
    id = Ecto.UUID.generate()
    {token, token_hash} = one_time_token(id)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:identity_available, fn _repo, _changes ->
      with :ok <- AdmissionQuotas.lock_tenant(tenant_id),
           :ok <- Accounts.ensure_invitation_identity_available(tenant_id, email) do
        {:ok, :available}
      end
    end)
    |> Ecto.Multi.insert(
      :invitation,
      Invitation.changeset(%Invitation{id: id}, %{
        tenant_id: tenant_id,
        invited_by_user_id: value(subject, :user_id),
        email: email,
        role: role,
        token_hash: token_hash,
        status: :pending,
        expires_at: invitation_expires_at(),
        idempotency_key: idempotency_key
      })
    )
    |> Audit.append(%{
      tenant_id: tenant_id,
      actor_user_id: value(subject, :user_id),
      action: "invitation.create",
      resource_type: "invitation",
      resource_id: id,
      metadata: %{email: email, role: role},
      request_id: value(subject, :request_id)
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{invitation: invitation}} ->
        {:ok, %{invitation: Projector.invitation(invitation), token: token, replayed: false}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp accept_locked(invitation_id, secret, password, display_name) do
    invitation =
      Repo.one(
        from(invitation in Invitation,
          where: invitation.id == ^invitation_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:invalid_invitation)

    cond do
      invitation.status != :pending ->
        {:error, :invalid_invitation}

      DateTime.compare(invitation.expires_at, now()) != :gt ->
        invitation
        |> Invitation.changeset(%{status: :expired})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        {:error, :invalid_invitation}

      not secure_hash_equals(invitation.token_hash, secret) ->
        {:error, :invalid_invitation}

      true ->
        quota_ok!(AdmissionQuotas.lock_tenant(invitation.tenant_id))

        identity_ok!(
          Accounts.ensure_invitation_identity_available(
            invitation.tenant_id,
            invitation.email
          )
        )

        quota_ok!(AdmissionQuotas.ensure_active_user_capacity(invitation.tenant_id))

        command = %InvitedUserCommand{
          tenant_id: invitation.tenant_id,
          email: invitation.email,
          display_name: display_name,
          role: invitation.role,
          password: password
        }

        user = Accounts.enroll_invited_user(command) |> identity_or_rollback()

        invitation
        |> Invitation.changeset(%{
          status: :accepted,
          accepted_user_id: user.id,
          accepted_at: now()
        })
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        audit_or_rollback(
          Audit.record(%{
            tenant_id: invitation.tenant_id,
            actor_user_id: user.id,
            action: "invitation.accept",
            resource_type: "invitation",
            resource_id: invitation.id,
            metadata: %{
              email: invitation.email,
              role: invitation.role,
              enrollment: "new_identity"
            }
          })
        )

        user
    end
  end

  defp expire_pending(tenant_id, email \\ nil) do
    query =
      from(invitation in Invitation,
        where:
          invitation.tenant_id == ^tenant_id and invitation.status == :pending and
            invitation.expires_at <= ^now()
      )

    query =
      if is_binary(email),
        do:
          where(
            query,
            [invitation],
            fragment("lower(?)", invitation.email) == ^String.downcase(email)
          ),
        else: query

    Repo.update_all(query, set: [status: :expired, updated_at: now()])
    :ok
  end

  defp existing_idempotent(_tenant_id, nil), do: nil

  defp existing_idempotent(tenant_id, key),
    do: Repo.get_by(Invitation, tenant_id: tenant_id, idempotency_key: key)

  defp one_time_token(id) do
    secret = :crypto.strong_rand_bytes(@token_bytes)
    {"#{id}.#{Base.url_encode64(secret, padding: false)}", :crypto.hash(:sha256, secret)}
  end

  defp parse_one_time_token(token) when is_binary(token) do
    case String.split(token, ".", parts: 2) do
      [id, encoded] ->
        with {:ok, _uuid} <- Ecto.UUID.cast(id),
             {:ok, secret} <- Base.url_decode64(encoded, padding: false) do
          {:ok, id, secret}
        else
          _ -> {:error, :invalid_invitation}
        end

      _ ->
        {:error, :invalid_invitation}
    end
  end

  defp parse_one_time_token(_token), do: {:error, :invalid_invitation}

  defp secure_hash_equals(hash, secret) when is_binary(hash) and is_binary(secret) do
    actual = :crypto.hash(:sha256, secret)
    byte_size(actual) == byte_size(hash) and :crypto.hash_equals(actual, hash)
  end

  defp secure_hash_equals(_hash, _secret), do: false

  defp invitation_expires_at do
    DateTime.add(
      now(),
      Application.get_env(:comms_core, :invitation_ttl_seconds, 604_800),
      :second
    )
  end

  defp requested_role(attrs) do
    case value(attrs, :role) do
      nil ->
        {:ok, :member}

      role when is_atom(role) and role in @invitation_roles ->
        {:ok, role}

      role when is_binary(role) ->
        case Enum.find(@invitation_roles, &(Atom.to_string(&1) == role)) do
          nil -> {:error, :invalid_role}
          normalized -> {:ok, normalized}
        end

      _ ->
        {:error, :invalid_role}
    end
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    normalized =
      cond do
        is_atom(status) and status in @invitation_statuses ->
          status

        is_binary(status) ->
          Enum.find(@invitation_statuses, &(Atom.to_string(&1) == status))

        true ->
          nil
      end

    if normalized, do: where(query, [invitation], invitation.status == ^normalized), else: query
  end

  defp expected_version(attrs) do
    case value(attrs, :version) || value(attrs, :lock_version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  defp required_reason(attrs) do
    case value(attrs, :reason) do
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

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp identity_or_rollback({:ok, user}), do: user
  defp identity_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp identity_ok!(:ok), do: :ok
  defp identity_ok!({:error, reason}), do: Repo.rollback(reason)

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
