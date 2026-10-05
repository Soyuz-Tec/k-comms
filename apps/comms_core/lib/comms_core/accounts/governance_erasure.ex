defmodule CommsCore.Accounts.GovernanceErasure do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    Device,
    GovernanceErasureCommand,
    GovernanceErasureReceipt,
    MemberWorkspaces,
    NotificationCommand,
    NotificationPort,
    Session,
    User
  }

  alias CommsCore.Repo

  @spec ensure_allowed(String.t(), String.t(), [String.t()]) ::
          :ok
          | {:error,
             :invalid_owner_exclusions
             | :last_owner_required
             | :not_found
             | :transaction_required}
  def ensure_allowed(tenant_id, user_id, excluded_user_ids) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not valid_uuid?(tenant_id) or not valid_uuid?(user_id) ->
        {:error, :not_found}

      not valid_owner_exclusions?(excluded_user_ids) ->
        {:error, :invalid_owner_exclusions}

      true ->
        case governance_erasure_target(
               tenant_id,
               user_id,
               Enum.uniq(excluded_user_ids)
             ) do
          {:ok, %User{}} -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  @spec erase(map()) ::
          {:ok, %{user_id: Ecto.UUID.t(), revoked_session_ids: [Ecto.UUID.t()]}}
          | {:error,
             :invalid_erasure_command
             | :last_owner_required
             | :not_found
             | :transaction_required
             | :user_erasure_failed}
  def erase(command) when is_map(command) do
    tenant_id = value(command, :tenant_id)
    user_id = value(command, :user_id)
    pending_deletion_user_ids = value(command, :pending_deletion_user_ids)
    timestamp = value(command, :timestamp)

    cond do
      not valid_command?(
        tenant_id,
        user_id,
        pending_deletion_user_ids,
        timestamp
      ) ->
        {:error, :invalid_erasure_command}

      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      true ->
        command = %GovernanceErasureCommand{
          tenant_id: tenant_id,
          user_id: user_id,
          pending_deletion_user_ids: Enum.uniq(pending_deletion_user_ids),
          timestamp: timestamp
        }

        with {:ok, receipt} <- drain(command),
             {:ok, _finalized} <- finalize(command) do
          {:ok, %{user_id: receipt.user_id, revoked_session_ids: receipt.revoked_session_ids}}
        end
    end
  end

  def erase(_command), do: {:error, :invalid_erasure_command}

  @spec drain(GovernanceErasureCommand.t()) ::
          {:ok, GovernanceErasureReceipt.t()} | {:error, atom()}
  def drain(%GovernanceErasureCommand{} = command) do
    with :ok <- validate_contribution(command),
         {:ok, %User{} = user} <-
           governance_erasure_target(
             command.tenant_id,
             command.user_id,
             Enum.uniq(command.pending_deletion_user_ids)
           ) do
      # Retain identity-write exclusion while admitted readers finish User FK
      # checks before their Sessions drain. No unique key changes happen here.
      revoked_session_ids = revoke_user_access(user, command.timestamp)

      # Both media domains join this same transaction before any strong key
      # anonymization lock. The original Session receipt remains unchanged.
      with :ok <- NotificationPort.execute(NotificationCommand.user_access_revoked(user.tenant_id, user.id, "governance_user_erasure")),
           :ok <- revoke_calls(user) do
        {:ok,
         %GovernanceErasureReceipt{user_id: user.id, revoked_session_ids: revoked_session_ids}}
      end
    end
  end

  def drain(_command), do: {:error, :invalid_erasure_command}

  @spec finalize(GovernanceErasureCommand.t()) ::
          {:ok, GovernanceErasureReceipt.t()} | {:error, atom()}
  def finalize(%GovernanceErasureCommand{} = command) do
    with :ok <- validate_contribution(command),
         {:ok, %User{} = user} <-
           governance_erasure_target(
             command.tenant_id,
             command.user_id,
             Enum.uniq(command.pending_deletion_user_ids)
           ),
         :ok <- ensure_drained(user),
         # Private organization retains User references. Scrub it while all
         # canonical User parents still hold the weaker identity-write fence.
         :ok <- MemberWorkspaces.erase_user!(user.tenant_id, user.id),
         :ok <- NotificationPort.execute(NotificationCommand.user_erased(user.tenant_id, user.id)),
         # The caller must finish all lower resource/content contributions before
         # this last identity step: unique key changes may strengthen the lock.
         {:ok, _anonymized_user} <- anonymize_user(user) do
      erase_enterprise_identity(user)
      {:ok, %GovernanceErasureReceipt{user_id: user.id, revoked_session_ids: []}}
    end
  end

  def finalize(_command), do: {:error, :invalid_erasure_command}

  defp validate_contribution(command) do
    cond do
      not valid_command?(
        command.tenant_id,
        command.user_id,
        command.pending_deletion_user_ids,
        command.timestamp
      ) ->
        {:error, :invalid_erasure_command}

      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      true ->
        :ok
    end
  end

  defp revoke_calls(user) do
    case user.tenant_id
         |> CallLifecycleCommand.user_access_revoked(user.id, "governance_user_erasure")
         |> CallLifecyclePort.revoke_identity_access() do
      {:ok, %CallLifecycleReceipt{}} -> :ok
      _ -> {:error, :user_erasure_failed}
    end
  end

  defp ensure_drained(user) do
    sessions =
      from(row in Session,
        where:
          row.tenant_id == ^user.tenant_id and row.user_id == ^user.id and is_nil(row.revoked_at)
      )

    devices =
      from(row in Device,
        where:
          row.tenant_id == ^user.tenant_id and row.user_id == ^user.id and is_nil(row.revoked_at)
      )

    if Repo.exists?(sessions) or Repo.exists?(devices),
      do: {:error, :user_erasure_not_drained},
      else: :ok
  end

  defp erase_enterprise_identity(user) do
    resource_ids =
      Repo.all(
        from(row in CommsCore.Accounts.ScimResource,
          where: row.tenant_id == ^user.tenant_id and row.user_id == ^user.id,
          select: row.id
        )
      )

    for resource_id <- resource_ids do
      Repo.update_all(
        from(row in CommsCore.Accounts.ScimResource,
          where: row.tenant_id == ^user.tenant_id and row.kind == "Group",
          update: [
            set: [
              members: fragment("array_remove(?, ?)", row.members, type(^resource_id, :binary_id))
            ]
          ]
        ),
        []
      )
    end

    Repo.delete_all(
      from(row in CommsCore.Accounts.MfaFactor,
        where: row.tenant_id == ^user.tenant_id and row.user_id == ^user.id
      )
    )

    Repo.delete_all(
      from(row in CommsCore.Accounts.AuthChallenge,
        where: row.tenant_id == ^user.tenant_id and row.user_id == ^user.id
      )
    )

    Repo.delete_all(
      from(row in CommsCore.Accounts.FederatedIdentity,
        where: row.tenant_id == ^user.tenant_id and row.user_id == ^user.id
      )
    )

    Repo.delete_all(
      from(row in CommsCore.Accounts.ScimResource,
        where: row.tenant_id == ^user.tenant_id and row.user_id == ^user.id
      )
    )

    :ok
  end

  defp governance_erasure_target(tenant_id, user_id, excluded_user_ids) do
    lock_tenant_users!(tenant_id)

    with %User{} = user <-
           Repo.one(
             from(candidate in User,
               where: candidate.id == ^user_id and candidate.tenant_id == ^tenant_id,
               lock: "FOR NO KEY UPDATE"
             )
           ),
         :ok <- ensure_owner_safe(user, excluded_user_ids) do
      {:ok, user}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_owner_safe(
         %User{
           role: :owner,
           status: :active,
           account_type: :human,
           access_scope: :workspace
         } = user,
         pending_deletion_user_ids
       ) do
    remaining =
      User
      |> where(
        [candidate],
        candidate.tenant_id == ^user.tenant_id and candidate.id != ^user.id and
          candidate.role == :owner and candidate.status == :active and
          candidate.account_type == :human and candidate.access_scope == :workspace and
          candidate.id not in ^pending_deletion_user_ids
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: {:error, :last_owner_required}, else: :ok
  end

  defp ensure_owner_safe(_user, _pending_deletion_user_ids), do: :ok

  defp anonymize_user(user) do
    anonymized = "deleted-#{user.id}"

    user
    |> User.changeset(%{
      external_subject: anonymized,
      avatar_url: nil,
      timezone: "Etc/UTC",
      presence_state: "offline",
      presence_expires_at: nil,
      dnd_until: nil,
      dnd_schedule: %{},
      display_name: "Deleted user",
      email: "#{anonymized}@invalid.example",
      status: :deleted
    })
    |> Ecto.Changeset.change(
      presence_state: "offline",
      presence_expires_at: nil,
      dnd_until: nil,
      dnd_schedule: %{}
    )
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :user_erasure_failed}
    end
  end

  defp revoke_user_access(user, timestamp) do
    session_query =
      from(s in Session,
        where: s.tenant_id == ^user.tenant_id and s.user_id == ^user.id and is_nil(s.revoked_at)
      )

    revoked_session_ids = session_query |> select([s], s.id) |> Repo.all()
    Repo.update_all(session_query, set: [revoked_at: timestamp, updated_at: timestamp])

    Device
    |> where(
      [d],
      d.tenant_id == ^user.tenant_id and d.user_id == ^user.id and is_nil(d.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: timestamp, updated_at: timestamp])

    revoked_session_ids
  end

  defp valid_command?(tenant_id, user_id, pending_deletion_user_ids, timestamp) do
    valid_uuid?(tenant_id) and valid_uuid?(user_id) and is_list(pending_deletion_user_ids) and
      Enum.all?(pending_deletion_user_ids, &valid_uuid?/1) and match?(%DateTime{}, timestamp)
  end

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp valid_owner_exclusions?(values) when is_list(values),
    do: Enum.all?(values, &valid_uuid?/1)

  defp valid_owner_exclusions?(_values), do: false

  defp lock_tenant_users!(tenant_id) do
    Repo.all(
      from(u in User,
        where: u.tenant_id == ^tenant_id,
        order_by: [asc: u.id],
        select: u.id,
        # Excludes every User write/delete without blocking KEY SHARE checks by
        # readers that already retain a Session. Erase drains those lower rows
        # before the later unique-key anonymization acquires a stronger lock.
        lock: "FOR NO KEY UPDATE"
      )
    )
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
