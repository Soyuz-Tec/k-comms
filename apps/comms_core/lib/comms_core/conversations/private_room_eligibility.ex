defmodule CommsCore.Conversations.PrivateRoomEligibility do
  @moduledoc "Local withdrawal contribution under already retained tenant/sorted User locks. Never re-enters Governance or contacts a provider."
  @behaviour CommsCore.Accounts.MatrixEligibilityPort
  import Ecto.Query
  alias CommsCore.Repo

  alias CommsCore.Conversations.{
    PrivateRoom,
    Membership,
    PrivateRooms,
    PrivateBudget,
    PrivateRoomControlPort,
    PrivateRoomControlReceipt,
    PrivateRoomProtectionPort
  }

  alias CommsCore.Accounts.{MatrixEligibilityCommand, MatrixEligibilityReceipt}
  @impl true
  @spec withdraw_user(MatrixEligibilityCommand.t()) ::
          {:ok, MatrixEligibilityReceipt.t()} | {:error, atom()}
  def withdraw_user(%MatrixEligibilityCommand{} = command) do
    if Repo.in_transaction?() do
      rooms =
        Repo.all(
          from(r in PrivateRoom,
            where:
              r.tenant_id == ^command.tenant_id and ^command.user_id in r.historical_user_ids and
                r.state in [:provisioning, :active, :rekey_pending],
            order_by: r.conversation_id,
            lock: "FOR UPDATE"
          )
        )

      if length(rooms) > 1000, do: Repo.rollback(:private_room_erase_capacity_exhausted)

      count =
        Enum.reduce(rooms, 0, fn room, count ->
          member =
            Repo.one(
              from(m in Membership,
                where:
                  m.tenant_id == ^command.tenant_id and m.conversation_id == ^room.conversation_id and
                    m.user_id == ^command.user_id and is_nil(m.left_at),
                lock: "FOR UPDATE"
              )
            )

          if member do
            mapping =
              room.matrix_members[command.user_id] || Repo.rollback(:private_room_lineage_unknown)

            Repo.update!(
              Membership.changeset(member, %{
                left_at: command.timestamp,
                lock_version: member.lock_version + 1
              })
            )

            # Provisioning ambiguity is NOT converted into an active room. A
            # withdrawal fences it permanently until governed provider cleanup.
            state = if room.state == :provisioning, do: :purge_pending, else: :rekey_pending

            Repo.update!(
              PrivateRoom.retained_changeset(room,
                state: state,
                generation: room.generation + 1,
                membership_epoch: room.membership_epoch + 1,
                pending_removed_matrix_user_ids:
                  Enum.uniq(
                    Enum.reject(
                      [
                        mapping["matrix_user_id"],
                        room.pending_removed_matrix_user_id | room.pending_removed_matrix_user_ids
                      ],
                      &is_nil/1
                    )
                  )
              )
            )

            count + 1
          else
            count
          end
        end)

      {:ok, %MatrixEligibilityReceipt{fenced_rooms: count}}
    else
      {:error, :transaction_required}
    end
  end

  # Called only by the same authorized private-room worker. Re-acquire the full
  # Governance→tenant→all Users→room prefix before each remote ban and receipt.
  def reconcile do
    ids =
      Repo.all(
        from(r in PrivateRoom,
          where:
            r.state == :rekey_pending and
              (fragment("cardinality(?) > 0", r.pending_removed_matrix_user_ids) or
                 not is_nil(r.pending_removed_matrix_user_id)),
          order_by: r.updated_at,
          limit: 20,
          select: r.id
        )
      )

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      deadline = PrivateBudget.new()

      case PrivateBudget.transaction(deadline, fn ->
             initial = Repo.get!(PrivateRoom, id)

             case PrivateRoomProtectionPort.protection(
                    initial.tenant_id,
                    initial.conversation_id,
                    initial.historical_user_ids
                  ) do
               {:ok, %{held: false, capture_blocked: false}} -> :ok
               _ -> Repo.rollback(:private_room_withdrawn)
             end

             query = %CommsCore.Accounts.MatrixParticipantsLockQuery{
               tenant_id: initial.tenant_id,
               user_ids: initial.historical_user_ids,
               deadline: deadline
             }

             case CommsCore.Accounts.lock_matrix_participants(query, nil) do
               {:ok, _} -> :ok
               {:error, reason} -> Repo.rollback(reason)
             end

             room = Repo.one!(from(r in PrivateRoom, where: r.id == ^id, lock: "FOR UPDATE"))

             if room.state != :rekey_pending or room.generation != initial.generation,
               do: Repo.rollback(:private_room_generation_stale)

             Enum.each(
               Enum.uniq(
                 Enum.reject(
                   [room.pending_removed_matrix_user_id | room.pending_removed_matrix_user_ids],
                   &is_nil/1
                 )
               ),
               fn user ->
                 control = %{PrivateRooms.command(room, deadline) | removed_matrix_user_id: user}

                 case PrivateRoomControlPort.execute(:remove_member, control) do
                   {:ok, %PrivateRoomControlReceipt{matrix_room_id: native}}
                   when native == room.matrix_room_id ->
                     PrivateBudget.check!(deadline)

                   {:error, reason} ->
                     Repo.rollback(reason)

                   _ ->
                     Repo.rollback(:private_room_provider_receipt_invalid)
                 end
               end
             )

             Repo.update!(
               PrivateRoom.retained_changeset(room,
                 state: :active,
                 pending_removed_matrix_user_id: nil,
                 pending_removed_matrix_user_ids: []
               )
             )

             :ok
           end) do
        {:ok, :ok} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
