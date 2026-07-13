defmodule CommsWeb.Broadcast do
  alias CommsCore.Conversations

  def event(conversation_id, event, payload)
      when is_binary(conversation_id) and is_binary(event) do
    CommsWeb.Endpoint.broadcast("conversation:#{conversation_id}", event, payload)
  end

  def conversation_activity(conversation_id, latest_sequence, event_type)
      when is_binary(conversation_id) and is_integer(latest_sequence) and is_binary(event_type) do
    payload = %{
      conversation_id: conversation_id,
      latest_sequence: latest_sequence,
      event_type: event_type
    }

    conversation_id
    |> Conversations.active_member_ids()
    |> Enum.each(&user(&1, "conversation.activity.v1", payload))

    :ok
  end

  def conversation_membership(user_id, conversation_id, action)
      when is_binary(user_id) and is_binary(conversation_id) and action in ["added", "removed"] do
    user(user_id, "conversation.membership.v1", %{
      conversation_id: conversation_id,
      action: action
    })
  end

  def conversation_memberships(conversation_id, action)
      when is_binary(conversation_id) and action in ["added", "removed"] do
    conversation_id
    |> Conversations.active_member_ids()
    |> Enum.each(&conversation_membership(&1, conversation_id, action))

    :ok
  end

  def user(user_id, event, payload)
      when is_binary(user_id) and is_binary(event) and is_map(payload) do
    CommsWeb.Endpoint.broadcast("user:#{user_id}", event, payload)
  end
end
