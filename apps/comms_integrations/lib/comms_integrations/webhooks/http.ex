defmodule CommsIntegrations.Webhooks.Http do
  @behaviour CommsIntegrations.Webhooks

  @impl true
  def deliver(payload) when is_map(payload) do
    with {:ok, url} <- fetch(payload, "url"),
         {:ok, secret} <- fetch(payload, "secret"),
         :ok <- validate_destination(url),
         {:ok, body} <- Jason.encode(Map.get(payload, "body") || Map.get(payload, :body) || %{}),
         request <- Finch.build(:post, url, headers(body, secret), body),
         {:ok, %Finch.Response{status: status}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch) do
      :ok
    else
      {:ok, %Finch.Response{status: status}} -> {:error, {:webhook_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :webhook_delivery_failed}
    end
  end

  def deliver(_), do: {:error, :invalid_webhook_request}

  defp validate_destination(url) do
    uri = URI.parse(url)
    allowed_hosts = Application.get_env(:comms_integrations, :webhook_allowed_hosts, [])

    if uri.scheme == "https" and is_binary(uri.host) and uri.host in allowed_hosts do
      :ok
    else
      {:error, :webhook_destination_not_allowed}
    end
  end

  defp headers(body, secret) do
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    [
      {"content-type", "application/json"},
      {"user-agent", "k-comms-webhook/0.2"},
      {"x-k-comms-signature", "sha256=#{signature}"}
    ]
  end

  defp fetch(payload, key) do
    case Map.get(payload, key) || Map.get(payload, atom_key(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_webhook_request}
    end
  end

  defp atom_key("url"), do: :url
  defp atom_key("secret"), do: :secret
end
