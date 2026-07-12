defmodule CommsIntegrations.Notifications.Http do
  @behaviour CommsIntegrations.Notifications

  alias CommsIntegrations.HttpPolicy

  @impl true
  def deliver(payload) when is_map(payload) do
    config = config()

    with %{status: :available} <- status(),
         endpoint <- Keyword.fetch!(config, :endpoint),
         {:ok, body} <- Jason.encode(provider_payload(payload)),
         {:ok, %{status: status, headers: headers, body: response_body}} <-
           CommsIntegrations.PinnedHttp.request(
             :post,
             endpoint,
             headers(payload, config),
             body,
             config
           ) do
      response(status, headers, response_body, config)
    else
      %{status: :unavailable} -> {:error, :notification_provider_unavailable}
      {:error, reason} when reason in [:outbound_dns_unavailable] -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, :permanent, reason}
      _ -> {:error, :notification_transport_error}
    end
  end

  def deliver(_), do: {:error, :permanent, :invalid_notification_request}

  @impl true
  def status do
    config = config()

    config
    |> HttpPolicy.https_configuration_status([:endpoint, :token, :allowed_hosts, :provider_name])
    |> Map.put(:adapter, "http")
  end

  defp response(status, headers, body, config) when status in 200..299 do
    {:ok,
     %{
       provider: Keyword.fetch!(config, :provider_name),
       http_status: status,
       provider_message_id: provider_message_id(headers, body)
     }}
  end

  defp response(status, _headers, _body, _config) when status in [408, 425, 429] or status >= 500,
    do: {:error, {:notification_status, status}}

  defp response(status, _headers, _body, _config),
    do: {:error, :permanent, {:notification_status, status}}

  defp provider_payload(payload) do
    %{
      channel: value(payload, :channel),
      destination: value(payload, :destination),
      event_type: value(payload, :event_type),
      data: value(payload, :payload) || %{}
    }
  end

  defp headers(payload, config) do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", "Bearer #{Keyword.fetch!(config, :token)}"},
      {"idempotency-key", value(payload, :idempotency_key)},
      {"user-agent", "k-comms-notifications/0.3"}
    ]
  end

  defp provider_message_id(headers, body) do
    header =
      Enum.find_value(headers, fn
        {key, value} when key in ["x-message-id", "x-request-id"] -> value
        _ -> nil
      end)

    header || json_id(body)
  end

  defp json_id(body) do
    case Jason.decode(body || "") do
      {:ok, %{"id" => id}} when is_binary(id) -> String.slice(id, 0, 255)
      _ -> nil
    end
  end

  defp config, do: Application.get_env(:comms_integrations, :notification_http, [])
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
