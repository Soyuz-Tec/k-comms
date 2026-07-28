defmodule CommsWeb.InAppNotificationPresenter do
  alias CommsCore.Notifications.IntentView

  def notification(%IntentView{} = intent) do
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

    if not String.starts_with?(value, "//") and is_nil(uri.scheme) and is_nil(uri.host) and
         safe_app_path?(uri.path) do
      uri
      |> Map.put(:path, canonical_app_path(uri.path))
      |> URI.to_string()
      |> String.slice(0, 1_000)
    end
  end

  defp safe_action_url(_), do: nil

  defp safe_app_path?(path) when is_binary(path) do
    decoded = URI.decode(path)
    segments = String.split(decoded, "/")

    (decoded == "/app" or String.starts_with?(decoded, "/app/")) and
      not String.contains?(decoded, "\\") and
      Enum.all?(segments, &(&1 not in [".", ".."]))
  rescue
    ArgumentError -> false
  end

  defp safe_app_path?(_), do: false

  defp canonical_app_path("/app"), do: "/app/"
  defp canonical_app_path(value), do: value

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))

  defp payload_value(_, _), do: nil
end
