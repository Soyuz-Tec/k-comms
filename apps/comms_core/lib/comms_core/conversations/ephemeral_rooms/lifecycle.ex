defmodule CommsCore.Conversations.EphemeralRooms.Lifecycle do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo, Whiteboards}

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsCore.Conversations.EphemeralRooms.{
    Authority,
    Events,
    Maintenance,
    Scheduler
  }

  @authority_horizon_seconds 24 * 60 * 60
  @global_reconcile_limit 100

  def reconcile(room_id, expected_generation) do
    with {:ok, room_id} <- Authority.cast_uuid(room_id),
         %EphemeralRoom{} = snapshot <- Repo.get(EphemeralRoom, room_id) do
      Repo.transaction(fn ->
        _policy = Authority.admission_policy!(snapshot.tenant_id)
        {_conversation, link, room} = Authority.lock_room_scope!(snapshot)

        cond do
          room.status == :expired ->
            :already_terminal

          room.generation != expected_generation ->
            :stale_generation

          live_presence?(room.id, Authority.now()) ->
            :active

          within_reconnect_grace?(room, Authority.now()) ->
            :active

          room.status == :idle ->
            Scheduler.enqueue_expiry!(room, room.expires_at)
            {:idle, room.expires_at, room.generation}

          true ->
            transition_to_idle!(room, link)
        end
      end)
      |> Authority.transaction_result()
    else
      _ -> {:error, :ephemeral_room_not_found}
    end
  end

  def reconcile_all(reconcile_fun) when is_function(reconcile_fun, 2) do
    scrubbed = Maintenance.scrub_expired_replay_capsules()
    leases_pruned = Maintenance.prune_terminal_presence_leases()
    join_receipts_pruned = Maintenance.prune_expired_join_receipts()

    candidates =
      Repo.all(
        from(room in EphemeralRoom,
          where: room.status in [:active, :idle],
          order_by: [asc: room.updated_at, asc: room.id],
          limit: @global_reconcile_limit,
          select: {room.id, room.generation}
        )
      )

    reconciled =
      Enum.count(candidates, fn {room_id, generation} ->
        match?({:ok, {:idle, _, _}}, reconcile_fun.(room_id, generation))
      end)

    {:ok,
     %{
       scanned: length(candidates),
       reconciled: reconciled,
       scrubbed: scrubbed,
       leases_pruned: leases_pruned,
       join_receipts_pruned: join_receipts_pruned
     }}
  end

  def expire(
        room_id,
        expected_generation,
        call_access_revoker,
        archived_conversation_revoker
      )
      when is_function(call_access_revoker, 4) and
             is_function(archived_conversation_revoker, 3) do
    with {:ok, room_id} <- Authority.cast_uuid(room_id),
         %EphemeralRoom{} = snapshot <- Repo.get(EphemeralRoom, room_id) do
      Repo.transaction(fn ->
        _policy = Authority.admission_policy!(snapshot.tenant_id)
        {conversation, link, room} = Authority.lock_room_scope!(snapshot)
        timestamp = Authority.now()

        cond do
          room.status == :expired ->
            :already_terminal

          room.generation != expected_generation ->
            :stale_generation

          room.status == :active or live_presence?(room.id, timestamp) ->
            :active

          DateTime.compare(room.expires_at, timestamp) == :gt ->
            {:not_due, max(DateTime.diff(room.expires_at, timestamp, :second), 1)}

          true ->
            expire_locked!(
              conversation,
              link,
              room,
              timestamp,
              call_access_revoker,
              archived_conversation_revoker
            )
        end
      end)
      |> Authority.transaction_result()
    else
      _ -> {:error, :ephemeral_room_not_found}
    end
  end

  def reactivate_room!(%EphemeralRoom{status: :active} = room, _link, _request_id),
    do: room

  def reactivate_room!(%EphemeralRoom{status: :idle} = room, link, request_id) do
    timestamp = Authority.now()
    deadline = DateTime.add(timestamp, @authority_horizon_seconds, :second)

    updated =
      room
      |> EphemeralRoom.changeset(%{
        status: :active,
        idle_since: nil,
        expires_at: nil,
        last_presence_at: timestamp,
        authority_expires_at: deadline,
        generation: room.generation + 1
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    updated = Authority.extend_link_and_admissions!(updated, link, deadline)

    Scheduler.enqueue_reconcile!(
      updated,
      DateTime.add(timestamp, updated.reconnect_grace_seconds, :second)
    )

    Events.emit!(
      updated,
      "ephemeral_room.reactivated.v1",
      nil,
      %{generation: updated.generation},
      request_id
    )

    updated
  end

  def reactivate_room!(%EphemeralRoom{}, _link, _request_id),
    do: Repo.rollback(:ephemeral_room_unavailable)

  defp transition_to_idle!(room, link) do
    inactivity_started_at = room.last_presence_at || room.inserted_at
    expires_at = DateTime.add(inactivity_started_at, room.idle_ttl_seconds, :second)
    generation = room.generation + 1

    updated =
      room
      |> EphemeralRoom.changeset(%{
        status: :idle,
        idle_since: inactivity_started_at,
        expires_at: expires_at,
        authority_expires_at: expires_at,
        generation: generation
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    Authority.shorten_link_and_admissions!(updated, link, expires_at)
    Scheduler.enqueue_expiry!(updated, expires_at)

    Events.emit!(
      updated,
      "ephemeral_room.idle.v1",
      nil,
      %{expires_at: DateTime.to_iso8601(expires_at), generation: generation},
      "ephemeral-room-reconcile:#{updated.id}:#{generation}"
    )

    {:idle, expires_at, generation}
  end

  defp expire_locked!(
         conversation,
         link,
         room,
         timestamp,
         call_access_revoker,
         archived_conversation_revoker
       ) do
    admissions =
      Repo.all(
        from(admission in GuestAdmission,
          where:
            admission.tenant_id == ^room.tenant_id and
              admission.conversation_id == ^room.conversation_id,
          order_by: [asc: admission.id],
          lock: "FOR UPDATE"
        )
      )

    memberships =
      Repo.all(
        from(membership in Membership,
          where:
            membership.tenant_id == ^room.tenant_id and
              membership.conversation_id == ^room.conversation_id,
          order_by: [asc: membership.id],
          lock: "FOR UPDATE"
        )
      )

    Enum.each(admissions, fn admission ->
      if is_nil(admission.revoked_at) and is_nil(admission.converted_at) do
        case Accounts.revoke_guest_session(admission.session_id, "ephemeral_room_expired") do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        admission
        |> GuestAdmission.changeset(%{revoked_at: timestamp})
        |> update_or_rollback()
      end
    end)

    Enum.each(memberships, fn membership ->
      if is_nil(membership.left_at) do
        membership
        |> Membership.changeset(%{left_at: timestamp})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        case call_access_revoker.(
               room.tenant_id,
               room.conversation_id,
               membership.user_id,
               "ephemeral_room_expired"
             ) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)

    unless link.revoked_at do
      link
      |> GuestLink.changeset(%{revoked_at: timestamp, expires_at: timestamp})
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()
    end

    archived =
      if conversation.archived_at do
        conversation
      else
        conversation
        |> Conversation.changeset(%{archived_at: timestamp})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()
      end

    case archived_conversation_revoker.(
           room.tenant_id,
           room.conversation_id,
           "ephemeral_room_expired"
         ) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # Reclaimed here, in the same transaction that ends every path to the board.
    # Archiving alone only makes it unreachable: the rows survive, retention only
    # ages messages, and governance erasure needs a deletion request nobody
    # files for an abandoned room. An instant room's board is working canvas,
    # not a durable document, so expiry is the end of its life.
    discarded =
      case Whiteboards.discard_for_expired_room(
             room.tenant_id,
             room.conversation_id,
             timestamp
           ) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end

    expired =
      room
      |> EphemeralRoom.changeset(%{
        status: :expired,
        expired_at: timestamp,
        expires_at: timestamp,
        generation: room.generation + 1
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    Events.emit!(
      expired,
      "ephemeral_room.expired.v1",
      nil,
      %{
        conversation_id: archived.id,
        generation: expired.generation,
        whiteboards_discarded: discarded.whiteboards_deleted,
        whiteboard_operations_discarded: discarded.whiteboard_operations_deleted
      },
      "ephemeral-room-expiry:#{expired.id}:#{expired.generation}"
    )

    :expired
  end

  defp live_presence?(room_id, timestamp) do
    Repo.exists?(
      from(lease in EphemeralPresenceLease,
        where:
          lease.ephemeral_room_id == ^room_id and is_nil(lease.closed_at) and
            lease.expires_at > ^timestamp
      )
    )
  end

  defp within_reconnect_grace?(room, timestamp) do
    baseline = room.last_presence_at || room.inserted_at

    DateTime.compare(DateTime.add(baseline, room.reconnect_grace_seconds, :second), timestamp) ==
      :gt
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
