defmodule CommsIntegrations.NativePush.Provider do
  @behaviour CommsCore.Notifications.NativePushProviderPort.Contract
  @moduledoc "Bounded official APNs HTTP/2 and FCM HTTP v1 transports. No provider response or secret is logged."
  alias CommsCore.Notifications.NativeDelivery
  alias CommsIntegrations.NativePush.ProviderTokens
  alias CommsIntegrations.PinnedHttp

  # This is approved attempt capability, not delivery qualification. Edge must
  # never inspect Worker transport credentials while evaluating registration.
  def status() do
    channels = Application.get_env(:comms_integrations, :native_push_channels, [])
    approved = is_list(channels) && channels != [] && length(channels) <= 3 &&
      Enum.uniq(channels) == channels && Enum.all?(channels, &(&1 in ["apns_alert", "apns_voip", "fcm"]))
    if Application.get_env(:comms_integrations, :native_push_provider_enabled, false) == true && approved,
      do: %{status: :available, channels: channels}, else: %{status: :unavailable, channels: []}
  end
  def deliver(%NativeDelivery{} = delivery, deadline) when is_integer(deadline) do
    capability = status()
    if capability.status == :available && delivery.channel in capability.channels &&
      DateTime.compare(delivery.expires_at, DateTime.utc_now()) == :gt &&
      System.monotonic_time(:millisecond) < deadline do
      send_delivery(delivery, deadline)
    else
      {:error, :unavailable}
    end
  rescue
    _ -> {:error, :uncertain}
  end
  def deliver(_, _), do: {:error, :rejected}

  def payload(%NativeDelivery{} = delivery) do
    %{"protocol_version" => "1", "wake_id" => delivery.wake_id,
      "expires_at" => DateTime.to_iso8601(delivery.expires_at), "kind" => "call"}
  end
  defp send_delivery(%{channel: channel} = delivery, deadline) when channel in ["apns_alert", "apns_voip"] do
    host = if delivery.environment == "sandbox", do: "api.sandbox.push.apple.com", else: "api.push.apple.com"
    type = if channel == "apns_voip", do: "voip", else: "alert"
    topic = delivery.application_id <> if(channel == "apns_voip", do: ".voip", else: "")
    aps = if channel == "apns_voip", do: %{}, else: %{"alert" => %{"title" => "K-Comms call", "body" => "Open K-Comms to review this call."}, "sound" => "default"}
    with true <- Regex.match?(~r/^[a-f0-9]{64}$/, delivery.token),
         {:ok, bearer} <- ProviderTokens.apns(),
         {:ok, body} <- Jason.encode(Map.put(payload(delivery), "aps", aps)),
         {:ok, response} <- request("https://" <> host <> "/3/device/" <> delivery.token,
           [{"authorization", "bearer " <> bearer}, {"content-type", "application/json"},
            {"apns-push-type", type}, {"apns-topic", topic}, {"apns-priority", "10"},
            {"apns-expiration", Integer.to_string(DateTime.to_unix(delivery.expires_at))},
            {"apns-collapse-id", delivery.wake_id}, {"apns-id", delivery.wake_id}], body, host, deadline, [:http2]) do
      apns_result(response)
    else
      {:error, :native_push_credentials_unavailable} -> {:error, :unavailable}
      false -> {:error, :invalid_token}
      _ -> {:error, :uncertain}
    end
  end
  defp send_delivery(%{channel: "fcm", environment: "production"} = delivery, deadline) do
    with {:ok, project, bearer} <- ProviderTokens.fcm(deadline),
         true <- Regex.match?(~r/^[a-z][a-z0-9-]{4,62}$/, project),
         {:ok, body} <- Jason.encode(%{"message" => %{"token" => delivery.token, "data" => payload(delivery),
           "android" => %{"priority" => "HIGH", "ttl" => "#{min(max(DateTime.diff(delivery.expires_at, DateTime.utc_now(), :second), 0), 30)}s",
             "collapse_key" => delivery.wake_id}}}),
         {:ok, response} <- request("https://fcm.googleapis.com/v1/projects/" <> project <> "/messages:send",
           [{"authorization", "Bearer " <> bearer}, {"content-type", "application/json"}], body,
           "fcm.googleapis.com", deadline, [:http1]) do
      fcm_result(response)
    else
      {:error, :native_push_credentials_unavailable} -> {:error, :unavailable}
      _ -> {:error, :uncertain}
    end
  end
  defp send_delivery(_, _), do: {:error, :rejected}
  defp request(url, headers, body, host, deadline, protocols) do
    budget = min(max(deadline - System.monotonic_time(:millisecond), 0), 2_000)
    if budget == 0, do: {:error, :outbound_timeout},
      else: PinnedHttp.request(:post, url, headers, body, allowed_hosts: [host], allowed_ports: [443],
        timeout_ms: budget, connect_timeout_ms: min(budget, 1_000), protocols: protocols, max_response_bytes: 8_192)
  end
  defp apns_result(%{status: status}) when status in 200..299, do: :ok
  defp apns_result(%{status: 410}), do: {:error, :invalid_token}
  defp apns_result(%{status: 400, body: body}) do
    case Jason.decode(body || "") do
      {:ok, %{"reason" => reason}} when reason in ["BadDeviceToken", "DeviceTokenNotForTopic"] -> {:error, :invalid_token}
      _ -> {:error, :rejected}
    end
  end
  defp apns_result(_), do: {:error, :rejected}
  defp fcm_result(%{status: status}) when status in 200..299, do: :ok
  defp fcm_result(%{status: status, body: body}) when status in [400, 404] do
    case Jason.decode(body || "") do
      {:ok, %{"error" => %{"details" => details}}} when is_list(details) ->
        if Enum.any?(details, &(&1["errorCode"] == "UNREGISTERED")), do: {:error, :invalid_token}, else: {:error, :rejected}
      _ -> {:error, :rejected}
    end
  end
  defp fcm_result(_), do: {:error, :rejected}
end
