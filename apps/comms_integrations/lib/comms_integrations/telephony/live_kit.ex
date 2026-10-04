defmodule CommsIntegrations.Telephony.LiveKit do
  @moduledoc "LiveKit SIP Twirp adapter with bounded calls and no automatic dial retries."
  @behaviour CommsCore.Telephony.ProviderWebhookPort.Contract

  alias CommsIntegrations.Telephony.{Config, LiveKitWebhook}

  @e164 ~r/^\+[1-9][0-9]{7,14}$/
  @webhook_events ~w(participant_joined participant_left participant_connection_aborted room_finished)

  def configured?, do: match?({:ok, %{enabled: true}}, Config.configuration())

  @impl true
  def verify_webhook(body, authorization) do
    with {:ok, event} <- LiveKitWebhook.verify(body, authorization),
         {:ok, normalized} <- normalize_webhook(event) do
      {:ok, Map.put(normalized, :admission_enabled, configured?())}
    end
  end

  @impl true
  def authorized_adapter?(caller), do: caller == __MODULE__

  def create_outbound(command, requester \\ &request/5)

  def create_outbound(command, requester) when is_map(command) and is_function(requester, 5) do
    with {:ok, %{enabled: true} = config} <- Config.configuration(),
         {:ok, body} <- outbound_body(command, config),
         {:ok, response} <-
           twirp(
             "SIP/CreateSIPParticipant",
             body,
             %{"sip" => %{"call" => true}},
             config,
             config.ring_timeout_seconds * 1_000 + 15_000,
             requester
           ) do
      outbound_response(response, command)
    else
      {:error, :invalid_telephony_command} = error ->
        error

      {:error, :telephony_provider_unavailable} = error ->
        error

      {:error, reason}
      when reason in [
             :telephony_provider_mode,
             :audio_provider_mode,
             :livekit_server_url,
             :livekit_api_url,
             :livekit_api_key,
             :livekit_api_secret,
             :telephony_ring_timeout_seconds,
             :telephony_max_duration_seconds
           ] ->
        {:error, :telephony_provider_unavailable}

      {:error, _} ->
        {:error, :telephony_outcome_unknown}

      _ ->
        {:error, :telephony_provider_unavailable}
    end
  end

  def create_outbound(_, _), do: {:error, :invalid_telephony_command}

  def get_participant(room, identity, requester \\ &request/5) do
    with true <- valid_text?(room) and valid_text?(identity),
         {:ok, %{enabled: true} = config} <- Config.control_configuration(),
         {:ok, response} <-
           twirp(
             "RoomService/GetParticipant",
             %{room: room, identity: identity},
             %{"video" => %{"room" => room, "roomAdmin" => true}},
             config,
             5_000,
             requester
           ) do
      participant_response(response, room, identity)
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end

  def end_call(room, requester \\ &request/5) do
    with true <- valid_text?(room),
         {:ok, %{enabled: true} = config} <- Config.control_configuration(),
         {:ok, response} <-
           twirp(
             "RoomService/DeleteRoom",
             %{room: room},
             %{"video" => %{"roomCreate" => true}},
             config,
             5_000,
             requester
           ) do
      if successful?(response) or not_found?(response),
        do: :ok,
        else: {:error, :telephony_provider_unavailable}
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end

  @doc "Normalizes authenticated provider events without trusting tenant or routing metadata."
  def normalize_webhook(%{"event" => event}) when event not in @webhook_events,
    do: {:error, :unsupported_provider_event}

  def normalize_webhook(event) when is_map(event) do
    participant = Map.get(event, "participant", %{})
    room = Map.get(event, "room", %{})
    attrs = if is_map(participant), do: Map.get(participant, "attributes", %{}), else: nil

    with true <- is_map(participant) and is_map(room) and is_map(attrs),
         true <- event["event"] in @webhook_events,
         true <- valid_text?(event["id"]) and valid_text?(room["name"]),
         {:ok, timestamp} <- timestamp(event["createdAt"] || event["created_at"]),
         true <-
           event["event"] == "room_finished" or
             (valid_text?(participant["identity"]) and valid_participant_sid?(participant["sid"])) do
      {:ok,
       %{
         event_id: event["id"],
         event_type: event["event"],
         room: room["name"],
         participant_identity: participant["identity"],
         participant_sid: participant["sid"],
         participant_kind: participant_kind(participant["kind"]),
         provider_call_id: attrs["sip.callID"],
         trunk_id: attrs["sip.trunkID"],
         from_number: attrs["sip.phoneNumber"],
         to_number: attrs["sip.trunkPhoneNumber"],
         sip_status: attrs["sip.callStatus"],
         occurred_at: timestamp
       }}
    else
      _ -> {:error, :invalid_provider_event}
    end
  end

  def normalize_webhook(_), do: {:error, :invalid_provider_event}

  defp outbound_body(command, config) do
    room = value(command, :provider_room)
    identity = value(command, :provider_identity)
    trunk = value(command, :outbound_trunk_id) || value(command, :trunk_id)
    from = value(command, :from_number)
    to = value(command, :to_number)

    if Enum.all?([room, identity, trunk], &valid_text?/1) and valid_number?(from) and
         valid_number?(to) do
      {:ok,
       %{
         sip_trunk_id: trunk,
         sip_call_to: to,
         sip_number: from,
         room_name: room,
         participant_identity: identity,
         hide_phone_number: false,
         wait_until_answered: true,
         ringing_timeout: "#{config.ring_timeout_seconds}s",
         max_call_duration: "#{config.max_duration_seconds}s"
       }}
    else
      {:error, :invalid_telephony_command}
    end
  end

  defp outbound_response(response, command) do
    with true <- successful?(response),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(response.body),
         id when is_binary(id) <- decoded["sipCallId"] || decoded["sip_call_id"],
         true <- valid_text?(id),
         true <- (decoded["roomName"] || decoded["room_name"]) == value(command, :provider_room),
         true <-
           (decoded["participantIdentity"] || decoded["participant_identity"]) ==
             value(command, :provider_identity) do
      {:ok,
       %{
         provider_call_id: id,
         provider_room: value(command, :provider_room),
         provider_identity: value(command, :provider_identity),
         state: :answered
       }}
    else
      _ -> dial_error(response)
    end
  end

  defp dial_error(%{body: body, status: status}) do
    decoded =
      case Jason.decode(body || "") do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    metadata = Map.get(decoded, "meta", %{})
    sip_code = if is_map(metadata), do: metadata["sip_status_code"], else: nil

    code = if is_binary(sip_code) or is_integer(sip_code), do: to_string(sip_code), else: ""

    case code do
      code when code in ["486", "600"] -> {:error, :busy}
      code when code in ["408", "480"] -> {:error, :no_answer}
      code when code in ["603", "607", "608"] -> {:error, :declined}
      _ when status in [400, 401, 403, 404, 422] -> {:error, :telephony_provider_unavailable}
      _ -> {:error, :telephony_outcome_unknown}
    end
  end

  defp participant_response(response, room, identity) do
    cond do
      not_found?(response) -> {:error, :not_found}
      successful?(response) -> decode_participant(response.body, room, identity)
      true -> {:error, :telephony_provider_unavailable}
    end
  end

  defp decode_participant(body, room, identity) do
    with {:ok, %{"identity" => ^identity, "attributes" => attrs}} <- Jason.decode(body),
         true <- is_map(attrs),
         true <- valid_text?(attrs["sip.callID"]),
         {:ok, state} <- participant_state(attrs["sip.callStatus"]) do
      {:ok,
       %{
         provider_room: room,
         provider_identity: identity,
         provider_call_id: attrs["sip.callID"],
         state: state
       }}
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end

  defp participant_state("active"), do: {:ok, :answered}

  defp participant_state(state) when state in ["dialing", "ringing", "automation"],
    do: {:ok, :ringing}

  defp participant_state("hangup"), do: {:ok, :ended}
  defp participant_state(_), do: {:error, :invalid_provider_state}

  defp participant_kind(kind) when kind in ["SIP", 3], do: :sip
  defp participant_kind(kind) when kind in [nil, "STANDARD", 0], do: :standard
  defp participant_kind(_), do: :other

  defp twirp(path, body, grants, config, timeout, requester) do
    now = System.system_time(:second)

    claims =
      Map.merge(grants, %{
        "iss" => config.api_key,
        "exp" => now + div(timeout, 1_000) + 30,
        "nbf" => now - 5,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      })

    headers = [
      {"authorization", "Bearer " <> sign(claims, config.api_secret)},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    endpoint = String.trim_trailing(config.api_url, "/") <> "/twirp/livekit." <> path
    uri = URI.parse(config.api_url)

    requester.(:post, endpoint, headers, Jason.encode!(body),
      allowed_hosts: [uri.host],
      allowed_ports: [uri.port],
      timeout_ms: timeout,
      max_response_bytes: 65_536
    )
  end

  defp request(method, url, headers, body, options) do
    uri = URI.parse(url)

    if uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
         Application.get_env(:comms_integrations, :allow_insecure_local_media) == true do
      if Process.whereis(CommsIntegrations.Finch) do
        Finch.request(Finch.build(method, url, headers, body), CommsIntegrations.Finch,
          receive_timeout: Keyword.fetch!(options, :timeout_ms)
        )
      else
        {:error, :telephony_provider_unavailable}
      end
    else
      CommsIntegrations.PinnedHttp.request(method, url, headers, body, options)
    end
  rescue
    _ -> {:error, :outbound_transport_error}
  catch
    :exit, _ -> {:error, :outbound_transport_error}
  end

  defp sign(claims, secret) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    input = header <> "." <> payload
    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, input), padding: false)
  end

  defp successful?(%{status: status}) when status in 200..299, do: true
  defp successful?(_), do: false

  defp not_found?(%{status: status, body: body}) when status in 400..499,
    do: match?({:ok, %{"code" => "not_found"}}, Jason.decode(body || ""))

  defp not_found?(_), do: false

  defp valid_text?(value),
    do: is_binary(value) and byte_size(value) in 1..255 and String.trim(value) != ""

  defp valid_participant_sid?(value),
    do: is_binary(value) and byte_size(value) in 1..200 and String.trim(value) != ""

  defp valid_number?(value), do: is_binary(value) and Regex.match?(@e164, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> timestamp(seconds)
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp(value) when is_integer(value) and value >= 0, do: DateTime.from_unix(value)
  defp timestamp(_), do: {:error, :invalid_timestamp}
end
