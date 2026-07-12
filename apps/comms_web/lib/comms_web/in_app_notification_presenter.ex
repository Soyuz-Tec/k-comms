defmodule CommsWeb.InAppNotificationPresenter do
  alias CommsCore.Notifications.Intent

  def notification(%Intent{} = intent) do
    {title, body} = copy(intent.event_type)

    %{
      id: intent.id,
      event_type: intent.event_type,
      title: title,
      body: body,
      conversation_id: safe_uuid(payload_value(intent.payload, "conversation_id")),
      message_id: safe_uuid(payload_value(intent.payload, "message_id")),
      action_url: safe_action_url(payload_value(intent.payload, "action_url")),
      read_at: intent.read_at,
      inserted_at: intent.inserted_at
    }
  end

  defp copy("mention.created.v1"),
    do: {"New mention", "You were mentioned in a conversation."}

  defp copy(_), do: {"New message", "A new message is ready to view."}

  defp safe_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> value
      :error -> nil
    end
  end

  defp safe_uuid(_), do: nil

  defp safe_action_url(value) when is_binary(value) do
    uri = URI.parse(value)

    if app_path?(value) and not String.starts_with?(value, "//") and
         is_nil(uri.scheme) and is_nil(uri.host),
       do: String.slice(value, 0, 1_000),
       else: nil
  end

  defp safe_action_url(_), do: nil

  defp app_path?(value),
    do:
      value == "/app" or String.starts_with?(value, "/app?") or
        String.starts_with?(value, "/app/")

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))

  defp payload_value(_, _), do: nil
end
