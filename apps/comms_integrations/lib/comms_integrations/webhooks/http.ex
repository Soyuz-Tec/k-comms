defmodule CommsIntegrations.Webhooks.Http do
  @behaviour CommsIntegrations.Webhooks

  @transient_transport_errors [
    :outbound_dns_unavailable,
    :outbound_timeout,
    :outbound_transport_error,
    :outbound_tls_error
  ]

  @destination_policy_errors [
    :outbound_https_required,
    :outbound_host_required,
    :outbound_credentials_forbidden,
    :outbound_fragment_forbidden,
    :outbound_port_not_allowed,
    :outbound_host_not_allowed,
    :outbound_ip_literal_forbidden,
    :outbound_private_address_forbidden
  ]

  @impl true
  def deliver(payload) when is_map(payload) do
    config = request_config()

    with {:ok, url} <- fetch(payload, "url"),
         {:ok, secret} <- fetch(payload, "secret"),
         {:ok, body} <- Jason.encode(value(payload, "body") || %{}),
         {:ok, %{status: status}} <-
           CommsIntegrations.PinnedHttp.request(
             :post,
             url,
             headers(payload, body, secret),
             body,
             config
           ) do
      response(status)
    else
      {:error, :permanent, _reason} = error ->
        error

      {:error, reason} when reason in @transient_transport_errors ->
        {:error, reason}

      {:error, {:webhook_status, _status}} = error ->
        error

      {:error, reason} when reason in @destination_policy_errors ->
        {:error, :permanent, :webhook_destination_not_allowed}

      {:error, reason} ->
        {:error, :permanent, reason}

      _ ->
        {:error, :permanent, :webhook_transport_error}
    end
  end

  def deliver(_), do: {:error, :permanent, :invalid_webhook_request}

  @impl true
  def status do
    allowed_hosts = Keyword.get(config(), :allowed_hosts, legacy_allowed_hosts())

    if allowed_hosts == [] do
      %{status: :unavailable, adapter: "http", reason: :webhook_allowed_hosts_not_configured}
    else
      %{status: :available, adapter: "http", allowed_host_count: length(allowed_hosts)}
    end
  end

  defp response(status) when status in 200..299,
    do: {:ok, %{provider: "http", http_status: status}}

  defp response(status) when status in [408, 425, 429] or status >= 500,
    do: {:error, {:webhook_status, status}}

  defp response(status), do: {:error, :permanent, {:webhook_status, status}}

  defp headers(payload, body, secret) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    signed_payload = timestamp <> "." <> body
    signature = :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

    [
      {"content-type", "application/json"},
      {"user-agent", "k-comms-webhook/0.3"},
      {"x-k-comms-delivery", safe_header(value(payload, "delivery_id"))},
      {"x-k-comms-event", safe_header(value(payload, "event_type"))},
      {"x-k-comms-timestamp", timestamp},
      {"x-k-comms-signature", "v1=#{signature}"},
      {"idempotency-key", safe_header(value(payload, "idempotency_key"))}
    ]
  end

  defp fetch(payload, key) do
    case value(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :permanent, :invalid_webhook_request}
    end
  end

  defp safe_header(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp safe_header(_), do: "unknown"
  defp config, do: Application.get_env(:comms_integrations, :webhook_http, [])

  defp request_config do
    Keyword.put_new(config(), :allowed_hosts, legacy_allowed_hosts())
  end

  defp legacy_allowed_hosts,
    do: Application.get_env(:comms_integrations, :webhook_allowed_hosts, [])

  defp value(payload, key) when is_binary(key),
    do: Map.get(payload, key) || Map.get(payload, key_atom(key))

  defp key_atom("url"), do: :url
  defp key_atom("secret"), do: :secret
  defp key_atom("body"), do: :body
  defp key_atom("delivery_id"), do: :delivery_id
  defp key_atom("event_type"), do: :event_type
  defp key_atom("idempotency_key"), do: :idempotency_key
  defp key_atom(_), do: :unknown
end
