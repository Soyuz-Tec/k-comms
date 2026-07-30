defmodule CommsCore.Conversations.EphemeralRooms.ConversionHooks do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo

  alias CommsCore.Conversations.{
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestLink
  }

  alias CommsCore.Conversations.EphemeralRooms.{Authority, Events, Scheduler}

  def lock_conversion_room(%GuestLink{purpose: :ephemeral_room} = link) do
    Repo.one(
      from(room in EphemeralRoom,
        where:
          room.tenant_id == ^link.tenant_id and room.conversation_id == ^link.conversation_id and
            room.guest_link_id == ^link.id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  def lock_conversion_room(%GuestLink{}), do: nil

  def upgrade_converted_owner(nil, _authentication, _timestamp, _request_id), do: false

  def upgrade_converted_owner(%EphemeralRoom{} = room, authentication, timestamp, request_id) do
    if room.creator_user_id == authentication.user.id and room.owner_kind == :guest do
      expires_at =
        if room.status == :idle do
          DateTime.add(room.idle_since, Authority.registered_idle_ttl(), :second)
        else
          nil
        end

      updated =
        room
        |> EphemeralRoom.changeset(%{
          owner_kind: :registered,
          creator_session_id: authentication.session_id,
          idle_ttl_seconds: Authority.registered_idle_ttl(),
          expires_at: expires_at,
          generation: room.generation + 1
        })
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

      updated =
        if updated.status == :idle do
          link = Repo.get!(GuestLink, updated.guest_link_id)
          Authority.extend_link_and_admissions!(updated, link, updated.expires_at)
        else
          updated
        end

      if updated.status == :idle do
        Scheduler.enqueue_expiry!(updated, updated.expires_at)
      else
        Scheduler.enqueue_reconcile!(
          updated,
          DateTime.add(timestamp, updated.reconnect_grace_seconds, :second)
        )
      end

      Events.emit!(
        updated,
        "ephemeral_room.owner_upgraded.v1",
        updated.creator_user_id,
        %{owner_kind: "registered", generation: updated.generation},
        request_id
      )

      true
    else
      false
    end
  end

  def handoff_converted_presence(
        nil,
        _old_session_id,
        _authentication,
        _timestamp
      ),
      do: 0

  def handoff_converted_presence(
        %EphemeralRoom{} = room,
        old_session_id,
        %{user: %{id: user_id}, session_id: new_session_id},
        %DateTime{} = timestamp
      )
      when is_binary(old_session_id) and is_binary(user_id) and is_binary(new_session_id) do
    {count, _} =
      Repo.update_all(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^room.id and lease.user_id == ^user_id and
              lease.session_id == ^old_session_id,
          update: [
            set: [
              session_id: ^new_session_id,
              closed_at: fragment("COALESCE(?, ?)", lease.closed_at, ^timestamp),
              updated_at: ^timestamp
            ]
          ]
        ),
        []
      )

    if count > 0 do
      current = Repo.get!(EphemeralRoom, room.id)

      Scheduler.enqueue_reconcile!(
        current,
        DateTime.add(timestamp, current.reconnect_grace_seconds, :second)
      )
    end

    count
  end

  def close_logged_out_presence(
        nil,
        _user_id,
        _session_id,
        _timestamp
      ),
      do: 0

  def close_logged_out_presence(
        %EphemeralRoom{} = room,
        user_id,
        session_id,
        %DateTime{} = timestamp
      )
      when is_binary(user_id) and is_binary(session_id) do
    {count, _} =
      Repo.update_all(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^room.id and lease.user_id == ^user_id and
              lease.session_id == ^session_id and is_nil(lease.closed_at)
        ),
        set: [closed_at: timestamp, updated_at: timestamp]
      )

    if count > 0 and room.status == :active do
      Scheduler.enqueue_reconcile!(
        room,
        DateTime.add(timestamp, room.reconnect_grace_seconds, :second)
      )
    end

    count
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
