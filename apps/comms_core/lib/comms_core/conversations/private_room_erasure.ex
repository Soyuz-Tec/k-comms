defmodule CommsCore.Conversations.PrivateRoomErasure do
  @moduledoc "Conservative historical-participant erasure. Native room purge is distinct from all-version key-backup and managed client-store cleanup proof."
  import Ecto.Query
  alias CommsCore.Repo

  alias CommsCore.Conversations.{
    PrivateBudget,
    PrivateRoom,
    PrivateRooms,
    PrivateRoomProtectionPort,
    PrivateRoomControlPort,
    PrivateRoomControlReceipt
  }

  def prepare(tenant, type, target) do
    if Repo.in_transaction?() do
      # Take Governance before every room; user erasure includes every derived
      # room where that user was ever a potential original author, even after
      # membership removal. No client-supplied lineage is accepted.
      with {:ok, _} <- PrivateRoomProtectionPort.protection(tenant, target, [target]) do
        rooms = Repo.all(candidates(tenant, type, target) |> lock("FOR UPDATE"))
        if length(rooms) > 1000, do: Repo.rollback(:private_room_erase_capacity_exhausted)

        Enum.each(rooms, fn room ->
          case PrivateRoomProtectionPort.protection(
                 tenant,
                 room.conversation_id,
                 room.historical_user_ids
               ) do
            {:ok, %{held: false}} -> :ok
            {:ok, %{held: true}} -> Repo.rollback(:legal_hold_active)
            {:error, reason} -> Repo.rollback(reason)
          end

          if length(room.historical_user_ids) not in 1..100 or
               map_size(room.matrix_members) != length(room.historical_user_ids),
             do: Repo.rollback(:private_room_lineage_unknown)

          if room.state not in [:purge_pending, :provider_purged, :erased],
            do:
              persist_private_room!(room,
                state: :purge_pending,
                generation: room.generation + 1,
                membership_epoch: room.membership_epoch + 1
              )
        end)

        {:ok, %{private_rooms_fenced: length(rooms)}}
      end
    else
      {:error, :transaction_required}
    end
  end

  def pending?(tenant, type, target) do
    {:ok,
     Repo.exists?(
       from(r in candidates(tenant, type, target),
         where: r.state != :erased or r.key_cleanup_state != "confirmed"
       )
     )}
  end

  def reconcile(caller) do
    if CommsCore.RuntimePorts.authorized_job_worker?(:private_room_purge_reconciler, caller) do
      case CommsCore.Conversations.PrivateRoomEligibility.reconcile() do
        :ok -> :ok
        # one fenced room cannot prevent unrelated governed purge work
        {:error, _} -> :ok
      end

      rooms =
        Repo.all(
          from(r in PrivateRoom,
            where: r.state == :purge_pending,
            order_by: r.updated_at,
            limit: 20
          )
        )

      Enum.reduce_while(rooms, {:ok, %{scanned: length(rooms), provider_purged: 0}}, fn room,
                                                                                        {:ok,
                                                                                         counts} ->
        case purge(room) do
          {:ok, true} -> {:cont, {:ok, %{counts | provider_purged: counts.provider_purged + 1}}}
          {:ok, false} -> {:cont, {:ok, counts}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  defp purge(room) do
    deadline = PrivateBudget.new()

    PrivateBudget.transaction(deadline, fn ->
      # Retain the legal-hold fence through the native destructive request;
      # rechecking after provider deletion would be too late.
      case PrivateRoomProtectionPort.protection(
             room.tenant_id,
             room.conversation_id,
             room.historical_user_ids
           ) do
        {:ok, %{held: false}} -> :ok
        _ -> Repo.rollback(:legal_hold_active)
      end

      retained = Repo.one!(from(r in PrivateRoom, where: r.id == ^room.id, lock: "FOR UPDATE"))

      if retained.generation != room.generation or retained.state != :purge_pending,
        do: Repo.rollback(:private_room_generation_stale)

      retained =
        if is_nil(retained.matrix_room_id) do
          case PrivateRoomControlPort.execute(
                 :recover_room,
                 PrivateRooms.command(retained, deadline)
               ) do
            {:ok, %PrivateRoomControlReceipt{matrix_room_id: id}} when is_binary(id) ->
              persist_private_room!(retained, matrix_room_id: id)

            {:error, reason} ->
              Repo.rollback(reason)
          end
        else
          retained
        end

      command = PrivateRooms.command(retained, deadline)
      action = if retained.purge_id, do: :purge_status, else: :purge

      receipt =
        case PrivateRoomControlPort.execute(action, command) do
          {:ok, %PrivateRoomControlReceipt{} = receipt} -> receipt
          {:error, reason} -> Repo.rollback(reason)
        end

      if receipt.matrix_room_id != retained.matrix_room_id,
        do: Repo.rollback(:private_room_provider_receipt_invalid)

      if receipt.provider_purged? == true do
        timestamp = DateTime.utc_now()

        persist_private_room!(retained,
          state: :provider_purged,
          purge_id: receipt.purge_id,
          provider_purged_at: timestamp
        )

        command = %CommsCore.Conversations.PrivateContentErasureCommand{
          tenant_id: room.tenant_id,
          conversation_id: room.conversation_id,
          generation: room.generation,
          matrix_room_id: retained.matrix_room_id,
          provider_purge_id: receipt.purge_id,
          timestamp: timestamp
        }

        case CommsCore.Conversations.PrivateContentErasurePort.erase_private_content(command) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        true
      else
        persist_private_room!(retained, purge_id: receipt.purge_id)
        false
      end
    end)
  end

  defp candidates(tenant, :user, target),
    do: from(r in PrivateRoom, where: r.tenant_id == ^tenant and ^target in r.historical_user_ids)

  defp candidates(tenant, :conversation, target),
    do: from(r in PrivateRoom, where: r.tenant_id == ^tenant and r.conversation_id == ^target)

  defp candidates(tenant, :message, _target),
    do: from(r in PrivateRoom, where: r.tenant_id == ^tenant and false)

  def authorize_content_erasure(%CommsCore.Conversations.PrivateContentErasureCommand{} = command) do
    if Repo.in_transaction?() do
      lineage =
        Repo.one(
          from(r in PrivateRoom,
            where:
              r.tenant_id == ^command.tenant_id and r.conversation_id == ^command.conversation_id,
            select: r.historical_user_ids
          )
        ) || []

      case PrivateRoomProtectionPort.protection(
             command.tenant_id,
             command.conversation_id,
             lineage
           ) do
        {:ok, %{held: false}} -> :ok
        _ -> Repo.rollback(:legal_hold_active)
      end

      case Repo.one(
             from(r in PrivateRoom,
               where:
                 r.tenant_id == ^command.tenant_id and
                   r.conversation_id == ^command.conversation_id and
                   r.generation == ^command.generation and
                   r.matrix_room_id == ^command.matrix_room_id and
                   r.purge_id == ^command.provider_purge_id and r.state == :provider_purged and
                   r.provider_purged_at == ^command.timestamp,
               lock: "FOR SHARE"
             )
           ) do
        %PrivateRoom{} -> :ok
        _ -> {:error, :private_room_purge_proof_required}
      end
    else
      {:error, :transaction_required}
    end
  end

  defp persist_private_room!(%PrivateRoom{} = record, attrs),
    do: Repo.update!(PrivateRoom.retained_changeset(record, attrs))
end
