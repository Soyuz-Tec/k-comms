defmodule CommsIntegrations.Scanner.Http do
  @behaviour CommsIntegrations.Scanner

  alias CommsIntegrations.HttpPolicy

  @verdicts ~w(clean malicious suspicious blocked)

  @impl true
  def scan(request) when is_map(request) do
    config = config()

    with %{status: :available} <- status(),
         endpoint <- Keyword.fetch!(config, :endpoint),
         {:ok, body} <- Jason.encode(scanner_payload(request)),
         {:ok, %{status: status, body: response_body}} <-
           CommsIntegrations.PinnedHttp.request(
             :post,
             endpoint,
             headers(config),
             body,
             config
           ) do
      response(status, response_body, config)
    else
      %{status: :unavailable} -> {:error, :scanner_unavailable}
      {:error, reason} when reason in [:outbound_dns_unavailable] -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, :permanent, reason}
      _ -> {:error, :scanner_transport_error}
    end
  end

  def scan(_), do: {:error, :permanent, :invalid_scanner_request}

  @impl true
  def status do
    config = config()

    config
    |> HttpPolicy.https_configuration_status([:endpoint, :token, :allowed_hosts, :provider_name])
    |> Map.put(:adapter, "http")
  end

  defp response(status, body, config) when status in 200..299 do
    case Jason.decode(body || "") do
      {:ok, %{"verdict" => verdict} = decoded} when verdict in @verdicts ->
        {:ok,
         %{
           verdict: verdict,
           provider: Keyword.fetch!(config, :provider_name),
           provider_reference: safe_reference(decoded["id"])
         }}

      _ ->
        {:error, :invalid_scanner_response}
    end
  end

  defp response(status, _body, _config) when status in [408, 425, 429] or status >= 500,
    do: {:error, {:scanner_status, status}}

  defp response(status, _body, _config), do: {:error, :permanent, {:scanner_status, status}}

  defp scanner_payload(request) do
    %{
      attachment_id: value(request, :attachment_id),
      content_type: value(request, :content_type),
      byte_size: value(request, :byte_size),
      checksum_sha256: value(request, :checksum_sha256),
      download: %{url: get_in(request, [:download, :url]) || get_in(request, ["download", "url"])}
    }
  end

  defp headers(config) do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", "Bearer #{Keyword.fetch!(config, :token)}"},
      {"user-agent", "k-comms-scanner/0.3"}
    ]
  end

  defp safe_reference(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp safe_reference(_), do: nil
  defp config, do: Application.get_env(:comms_integrations, :scanner_http, [])
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
