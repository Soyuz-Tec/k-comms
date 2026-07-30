defmodule CommsCore.Conversations.EphemeralRooms.Maintenance do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo

  alias CommsCore.Conversations.{
    EphemeralJoinReceipt,
    EphemeralPresenceLease,
    EphemeralRoom
  }

  @global_reconcile_limit 100
  @presence_incident_retention_seconds 60 * 60
  @join_receipt_tombstone_seconds 24 * 60 * 60

  def scrub_expired_replay_capsules do
    timestamp = now()

    ids =
      Repo.all(
        from(room in EphemeralRoom,
          where: room.idempotency_expires_at <= ^timestamp and not is_nil(room.replay_ciphertext),
          order_by: [asc: room.idempotency_expires_at, asc: room.id],
          limit: @global_reconcile_limit,
          select: room.id
        )
      )

    case ids do
      [] ->
        0

      ids ->
        {count, _} =
          Repo.update_all(
            from(room in EphemeralRoom, where: room.id in ^ids),
            set: [
              replay_ciphertext: nil,
              replay_nonce: nil,
              replay_tag: nil,
              replay_key_id: nil,
              replay_erased_at: timestamp,
              updated_at: timestamp
            ]
          )

        count
    end
  end

  def prune_terminal_presence_leases do
    cutoff =
      now()
      |> DateTime.add(
        -(reconnect_grace() + @presence_incident_retention_seconds),
        :second
      )

    ids =
      Repo.all(
        from(lease in EphemeralPresenceLease,
          where:
            (not is_nil(lease.closed_at) and lease.closed_at <= ^cutoff) or
              (is_nil(lease.closed_at) and lease.expires_at <= ^cutoff),
          order_by: [
            asc: fragment("COALESCE(?, ?)", lease.closed_at, lease.expires_at),
            asc: lease.id
          ],
          limit: @global_reconcile_limit,
          select: lease.id
        )
      )

    case ids do
      [] ->
        0

      ids ->
        Repo.delete_all(from(lease in EphemeralPresenceLease, where: lease.id in ^ids)) |> elem(0)
    end
  end

  def prune_expired_join_receipts do
    cutoff = DateTime.add(now(), -@join_receipt_tombstone_seconds, :second)

    ids =
      Repo.all(
        from(receipt in EphemeralJoinReceipt,
          where: receipt.expires_at <= ^cutoff,
          order_by: [asc: receipt.expires_at, asc: receipt.id],
          limit: @global_reconcile_limit,
          select: receipt.id
        )
      )

    case ids do
      [] ->
        0

      ids ->
        Repo.delete_all(from(receipt in EphemeralJoinReceipt, where: receipt.id in ^ids))
        |> elem(0)
    end
  end

  defp reconnect_grace,
    do: Application.get_env(:comms_core, :instant_room_reconnect_grace_seconds, 90)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
