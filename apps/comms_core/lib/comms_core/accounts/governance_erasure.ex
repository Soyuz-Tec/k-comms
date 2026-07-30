defmodule CommsCore.Accounts.GovernanceErasure do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, User}
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
        erase(
          tenant_id,
          user_id,
          Enum.uniq(pending_deletion_user_ids),
          timestamp
        )
    end
  end

  def erase(_command), do: {:error, :invalid_erasure_command}

  defp erase(tenant_id, user_id, pending_deletion_user_ids, timestamp) do
    with {:ok, %User{} = user} <-
           governance_erasure_target(tenant_id, user_id, pending_deletion_user_ids),
         {:ok, _anonymized_user} <- anonymize_user(user),
         revoked_session_ids <- revoke_user_access(user, timestamp) do
      {:ok, %{user_id: user.id, revoked_session_ids: revoked_session_ids}}
    end
  end

  defp governance_erasure_target(tenant_id, user_id, excluded_user_ids) do
    lock_tenant_users!(tenant_id)

    with %User{} = user <-
           Repo.one(
             from(candidate in User,
               where: candidate.id == ^user_id and candidate.tenant_id == ^tenant_id,
               lock: "FOR UPDATE"
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
         %User{role: :owner, status: :active} = user,
         pending_deletion_user_ids
       ) do
    remaining =
      User
      |> where(
        [candidate],
        candidate.tenant_id == ^user.tenant_id and candidate.id != ^user.id and
          candidate.role == :owner and candidate.status == :active and
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
      display_name: "Deleted user",
      email: "#{anonymized}@invalid.example",
      status: :deleted
    })
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
        lock: "FOR UPDATE"
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
