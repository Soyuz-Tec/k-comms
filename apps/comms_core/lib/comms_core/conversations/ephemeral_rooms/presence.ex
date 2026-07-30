defmodule CommsCore.Conversations.EphemeralRooms.Presence do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo}

  alias CommsCore.Conversations.{
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestAdmission,
    GuestLink
  }

  alias CommsCore.Conversations.EphemeralRooms.{
    Authority,
    Lifecycle,
    Projection,
    Request,
    Scheduler
  }

  @max_active_leases_per_user 5

  @spec open(map()) :: {:ok, map()} | {:error, term()}
  def open(attrs) when is_map(attrs), do: upsert(attrs, :open)
  def open(_attrs), do: {:error, :forbidden}

  @spec heartbeat(map()) :: {:ok, map()} | {:error, term()}
  def heartbeat(attrs) when is_map(attrs), do: upsert(attrs, :heartbeat)
  def heartbeat(_attrs), do: {:error, :forbidden}

  @spec close(map()) :: {:ok, map()} | {:error, term()}
  def close(attrs) when is_map(attrs) do
    with {:ok, grant} <- Accounts.access_grant(attrs),
         {:ok, conversation_id} <- Authority.cast_uuid(Request.value(attrs, :conversation_id)),
         {:ok, connection_secret} <-
           Request.idempotency_secret(Request.value(attrs, :connection_id)),
         %EphemeralRoom{} = snapshot <-
           Repo.get_by(EphemeralRoom,
             tenant_id: grant.tenant_id,
             conversation_id: conversation_id
           ) do
      Repo.transaction(fn ->
        _policy = Authority.admission_policy!(snapshot.tenant_id)
        {_conversation, _link, room} = Authority.lock_room_scope!(snapshot)
        authorize!(room, grant)

        lease =
          Repo.one(
            from(lease in EphemeralPresenceLease,
              where:
                lease.ephemeral_room_id == ^room.id and
                  lease.connection_digest == ^Request.digest(connection_secret) and
                  lease.user_id == ^grant.user_id and lease.session_id == ^grant.session_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:ephemeral_presence_not_found)

        timestamp = Authority.now()

        closed =
          if lease.closed_at do
            lease
          else
            lease
            |> EphemeralPresenceLease.changeset(%{
              last_seen_at: timestamp,
              expires_at: DateTime.add(timestamp, 1, :second),
              closed_at: timestamp
            })
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()
          end

        disconnect_at = closed.closed_at || timestamp
        updated_room = advance_last_presence!(room, disconnect_at)
        reconcile_at = DateTime.add(disconnect_at, updated_room.reconnect_grace_seconds, :second)
        Scheduler.enqueue_reconcile!(updated_room, reconcile_at)

        %{
          room: Projection.room(updated_room),
          generation: updated_room.generation,
          reconcile_at: reconcile_at,
          lease_id: closed.id
        }
      end)
      |> Authority.transaction_result()
    else
      _ -> {:error, :forbidden}
    end
  end

  def close(_attrs), do: {:error, :forbidden}

  defp upsert(attrs, mode) when mode in [:open, :heartbeat] do
    with {:ok, grant} <- Accounts.access_grant(attrs),
         {:ok, conversation_id} <- Authority.cast_uuid(Request.value(attrs, :conversation_id)),
         {:ok, connection_secret} <-
           Request.idempotency_secret(Request.value(attrs, :connection_id)),
         %EphemeralRoom{} = snapshot <-
           Repo.get_by(EphemeralRoom,
             tenant_id: grant.tenant_id,
             conversation_id: conversation_id
           ) do
      Repo.transaction(fn ->
        _policy = Authority.admission_policy!(snapshot.tenant_id)
        {conversation, link, room} = Authority.lock_room_scope!(snapshot)
        timestamp = Authority.now()
        Authority.available_room!(room, link, conversation, timestamp)
        authorize!(room, grant)
        room = Lifecycle.reactivate_room!(room, link, Request.value(attrs, :request_id))
        {deadline, room} = Authority.ensure_rolling_authority!(room, false)
        maybe_extend_present_guest!(room, grant, deadline)

        digest = Request.digest(connection_secret)
        expires_at = DateTime.add(timestamp, Authority.presence_lease_seconds(), :second)

        current =
          Repo.one(
            from(lease in EphemeralPresenceLease,
              where: lease.ephemeral_room_id == ^room.id and lease.connection_digest == ^digest,
              lock: "FOR UPDATE"
            )
          )

        lease =
          case {mode, current} do
            {:heartbeat, nil} ->
              Repo.rollback(:ephemeral_presence_not_found)

            {:open, nil} ->
              enforce_lease_limit!(room.id, grant.user_id, timestamp)

              %EphemeralPresenceLease{}
              |> EphemeralPresenceLease.changeset(%{
                tenant_id: room.tenant_id,
                ephemeral_room_id: room.id,
                conversation_id: room.conversation_id,
                user_id: grant.user_id,
                session_id: grant.session_id,
                connection_digest: digest,
                opened_at: timestamp,
                last_seen_at: timestamp,
                expires_at: expires_at
              })
              |> insert_or_rollback()

            {_mode, %EphemeralPresenceLease{} = lease}
            when lease.user_id == grant.user_id and lease.session_id == grant.session_id ->
              lease
              |> EphemeralPresenceLease.changeset(%{
                last_seen_at: timestamp,
                expires_at: expires_at,
                closed_at: nil
              })
              |> Ecto.Changeset.optimistic_lock(:lock_version)
              |> update_or_rollback()

            _ ->
              Repo.rollback(:forbidden)
          end

        updated_room =
          room
          |> EphemeralRoom.changeset(%{last_presence_at: timestamp})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        %{
          room: Projection.room(updated_room),
          lease: %{id: lease.id, expires_at: lease.expires_at},
          generation: updated_room.generation
        }
      end)
      |> Authority.transaction_result()
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize!(room, grant) do
    valid_membership? =
      Authority.active_membership?(room.tenant_id, room.conversation_id, grant.user_id)

    valid_guest? =
      grant.account_type != :guest or
        Repo.exists?(
          from(admission in GuestAdmission,
            join: link in GuestLink,
            on: link.id == admission.guest_link_id,
            where:
              admission.tenant_id == ^room.tenant_id and
                admission.conversation_id == ^room.conversation_id and
                admission.guest_user_id == ^grant.user_id and
                admission.session_id == ^grant.session_id and is_nil(admission.revoked_at) and
                is_nil(admission.converted_at) and link.purpose == :ephemeral_room
          )
        )

    unless valid_membership? and valid_guest?, do: Repo.rollback(:forbidden)
  end

  defp maybe_extend_present_guest!(room, %{account_type: :guest} = grant, deadline) do
    admission =
      Repo.one(
        from(admission in GuestAdmission,
          join: link in GuestLink,
          on: link.id == admission.guest_link_id,
          where:
            admission.tenant_id == ^room.tenant_id and
              admission.conversation_id == ^room.conversation_id and
              admission.guest_user_id == ^grant.user_id and
              admission.session_id == ^grant.session_id and is_nil(admission.revoked_at) and
              is_nil(admission.converted_at) and link.purpose == :ephemeral_room,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:forbidden)

    if DateTime.compare(admission.expires_at, deadline) != :eq do
      admission
      |> GuestAdmission.changeset(%{expires_at: deadline})
      |> update_or_rollback()
    end

    :ok
  end

  defp maybe_extend_present_guest!(_room, _grant, _deadline), do: :ok

  defp advance_last_presence!(room, timestamp) do
    case room.last_presence_at do
      %DateTime{} = current ->
        if DateTime.compare(current, timestamp) in [:eq, :gt],
          do: room,
          else: update_last_presence!(room, timestamp)

      _ ->
        update_last_presence!(room, timestamp)
    end
  end

  defp update_last_presence!(room, timestamp) do
    room
    |> EphemeralRoom.changeset(%{last_presence_at: timestamp})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()
  end

  defp enforce_lease_limit!(room_id, user_id, timestamp) do
    active_count =
      Repo.aggregate(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^room_id and lease.user_id == ^user_id and
              is_nil(lease.closed_at) and lease.expires_at > ^timestamp
        ),
        :count
      )

    if active_count < @max_active_leases_per_user,
      do: :ok,
      else: Repo.rollback(:ephemeral_presence_limit_exceeded)
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
