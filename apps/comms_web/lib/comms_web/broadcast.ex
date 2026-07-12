defmodule CommsWeb.Broadcast do
  def event(conversation_id, event, payload)
      when is_binary(conversation_id) and is_binary(event) do
    CommsWeb.Endpoint.broadcast("conversation:#{conversation_id}", event, payload)
  end
end
