defmodule CommsCore.Conversations.EphemeralRooms.Projection do
  @moduledoc false

  alias CommsCore.Conversations.{
    EphemeralRoomView,
    GuestAdmissionView,
    Projector
  }

  def response(room, conversation, token, authentication, admission, membership, replayed) do
    %{
      room: room(room),
      conversation: Projector.conversation(conversation),
      join_token: token,
      authentication: authentication,
      admission: admission(admission),
      membership: membership(membership),
      capabilities: nil,
      replayed: replayed
    }
  end

  def join_response(
        room,
        conversation,
        token,
        authentication,
        admission,
        membership,
        replayed,
        membership_changed
      )
      when is_boolean(membership_changed) do
    room
    |> response(conversation, token, authentication, admission, membership, replayed)
    |> Map.put(:membership_changed, membership_changed)
  end

  def room(room) do
    %EphemeralRoomView{
      id: room.id,
      conversation_id: room.conversation_id,
      owner_user_id: room.creator_user_id,
      status: room.status,
      owner_kind: room.owner_kind,
      participant_limit: room.participant_limit,
      idle_since: room.idle_since,
      expires_at: room.expires_at,
      inserted_at: room.inserted_at,
      updated_at: room.updated_at
    }
  end

  def admission(nil), do: nil

  def admission(admission) do
    %GuestAdmissionView{
      id: admission.id,
      conversation_id: admission.conversation_id,
      guest_link_id: admission.guest_link_id,
      guest_user_id: admission.guest_user_id,
      membership_id: admission.membership_id,
      session_id: admission.session_id,
      admitted_at: admission.admitted_at,
      expires_at: admission.expires_at,
      revoked_at: admission.revoked_at,
      converted_at: admission.converted_at,
      history_from_sequence: admission.history_from_sequence
    }
  end

  def membership(nil), do: nil

  def membership(membership),
    do: %{id: membership.id, user_id: membership.user_id, role: membership.role}
end
