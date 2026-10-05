defmodule CommsIntegrations.Telephony.AsteriskARI do
  @moduledoc """
  Optional qualified PBX control plane behind LiveKit SIP.

  Channel variables are set by the trusted PBX dialplan, never by browser or SIP
  caller input. Exact tenant/call/room/identity bindings are required on both legs.
  Read-before-write reconciliation and deterministic bridge/channel IDs preserve
  recovery without redialing an uncertain consultation.
  """
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract
  alias CommsIntegrations.Telephony.LiveKit

  @actions [
    :hold,
    :resume,
    :consult_transfer,
    :complete_transfer,
    :cancel_transfer,
    :voicemail,
    :queues,
    :shared_lines
  ]
  @impl true
  def capabilities() do
    configured = match?({:ok, _}, configuration())

    qualified =
      configured and
        Application.get_env(:comms_integrations, :telephony_pbx_qualified, false) == true

    native = LiveKit.capabilities()

    capabilities =
      Map.merge(
        native,
        Map.new(
          @actions,
          &{&1,
           %{
             supported: qualified,
             configured: configured,
             qualified: qualified,
             reason: if(qualified, do: nil, else: "pbx_not_qualified"),
             transport: "asterisk_ari",
             assurance: "provider_state"
           }}
        )
      )

    secret = Application.get_env(:comms_integrations, :telephony_pbx_webhook_secret)

    if is_binary(secret) and byte_size(secret) >= 32,
      do: capabilities,
      else:
        Map.put(capabilities, :voicemail, %{
          supported: false,
          configured: configured,
          qualified: false,
          reason: "pbx_event_verification_required"
        })
  end

  @impl true
  def authorize_destination(destination) do
    prefixes = Application.get_env(:comms_integrations, :telephony_pbx_destination_prefixes, [])
    valid = is_binary(destination) and Regex.match?(~r/^\+[1-9][0-9]{7,14}$/, destination)

    if valid and is_list(prefixes) and
         Enum.any?(
           prefixes,
           &(is_binary(&1) and Regex.match?(~r/^\+[1-9][0-9]{0,14}$/, &1) and
               String.starts_with?(destination, &1))
         ), do: :ok, else: {:error, :telephony_destination_forbidden}
  end

  @impl true
  def execute_control(command),
    do: execute_control(command, &CommsIntegrations.PinnedHttp.request/5)

  def execute_control(%{action: :blind_transfer} = command, _requester),
    do: LiveKit.execute_control(command)

  def execute_control(%{action: :queue_waiting} = command, requester) do
    case wait_in_queue(command, requester) do
      :ok -> {:ok, :submitted}
      error -> error
    end
  end

  def execute_control(command, requester) do
    with true <- get_in(capabilities(), [command.action, :supported]) == true,
         {:ok, configured} <- configuration(),
         config =
           Map.put(configured, :control_deadline, System.monotonic_time(:millisecond) + 15_000),
         {:ok, bindings} <- bindings(command, config, requester),
         {:ok, state} <- execute(command, bindings, config, requester) do
      {:ok, %{control_state: state, pbx_state: bindings}}
    else
      false -> {:error, :telephony_control_unsupported}
      {:error, _} = error -> error
      _ -> {:error, :telephony_outcome_unknown}
    end
  end

  @impl true
  def cleanup_call(command) do
    with :ok <- cleanup_call(command, &CommsIntegrations.PinnedHttp.request/5),
         do: CommsIntegrations.Telephony.end_call(command.provider_room)
  end

  # Admission flags may be disabled while cleanup is still obligatory. Retain
  # credentials until every durable provider cleanup receipt has been verified.
  def cleanup_call(command, requester) do
    with {:ok, configured} <- control_configuration(),
         config =
           Map.put(configured, :control_deadline, System.monotonic_time(:millisecond) + 20_000),
         {:ok, resources} <- cleanup_resources(command, config, requester),
         :ok <- delete_owned_channels(resources.channels, command, config, requester),
         :ok <- delete_owned_bridges(resources.bridges, config, requester),
         {:ok, remaining} <- cleanup_resources(command, config, requester),
         true <-
           remaining.channels == [] and remaining.bridges == [] and
             not Enum.any?(resources.channels, &(&1 in remaining.all_channel_ids)) and
             not Enum.any?(resources.bridges, &(&1 in remaining.all_bridge_ids)) do
      :ok
    else
      false -> {:error, :telephony_provider_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  @impl true
  def bound_call_status(command),
    do: bound_call_status(command, &CommsIntegrations.PinnedHttp.request/5)

  def bound_call_status(command, requester) do
    with {:ok, configured} <- control_configuration(),
         config =
           Map.put(configured, :control_deadline, System.monotonic_time(:millisecond) + 5_000),
         true <- is_map(command.pbx_state) and map_size(command.pbx_state) > 0,
         {:ok, resources} <- cleanup_resources(command, config, requester) do
      external_alive = command.pbx_state["external"] in resources.channels
      consult_alive = command.pbx_state["consult"] in resources.channels

      handed_off =
        command.control_state == "transferred" or
          command.pbx_state["app"] not in resources.channels

      if external_alive and
           (command.control_state == "voicemail" or not handed_off or consult_alive),
         do: {:ok, :active},
         else: {:ok, :ended}
    else
      {:error, _} = error -> error
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp cleanup_resources(command, config, requester) do
    saved = command.pbx_state || %{}
    holding = "kc_hold_" <> compact(command.call_id)
    consult = "kc_consult_" <> compact(command.call_id)
    destination_bridge = "kc_ivr_mix_" <> compact(command.call_id)

    with true <- valid_cleanup_bindings?(saved, holding, consult, destination_bridge),
         {:ok, channels} when is_list(channels) <- call(:get, "/channels", %{}, config, requester),
         {:ok, bridges} when is_list(bridges) <- call(:get, "/bridges", %{}, config, requester),
         true <- length(channels) <= 2_000 and length(bridges) <= 2_000,
         true <-
           Enum.all?(channels, fn channel ->
             is_map(channel) and safe_id?(channel["id"]) and
               is_map(channel["channelvars"] || %{})
           end),
         true <-
           Enum.all?(bridges, fn bridge ->
             is_map(bridge) and safe_id?(bridge["id"]) and
               is_list(bridge["channels"]) and length(bridge["channels"]) <= 2_000
           end),
         true <-
           length(Enum.uniq_by(channels, & &1["id"])) == length(channels) and
             length(Enum.uniq_by(bridges, & &1["id"])) == length(bridges),
         owned = Enum.filter(channels, &bound?(&1, command)),
         true <- safe_cleanup_channels?(owned, channels, command, saved, consult),
         ids = Enum.map(owned, & &1["id"]),
         owned_bridges =
           Enum.filter(bridges, fn bridge ->
             bridge["id"] in [holding, saved["mixing"], saved["destination_bridge"]] or
               Enum.any?(bridge["channels"] || [], &(&1 in ids))
           end),
         true <-
           Enum.all?(owned_bridges, fn bridge ->
             safe_id?(bridge["id"]) and is_list(bridge["channels"]) and
               length(bridge["channels"]) <= 3 and
               Enum.all?(bridge["channels"], &(&1 in ids)) and
               bridge["bridge_type"] in ["holding", "mixing"]
           end) do
      {:ok,
       %{
         channels: ids,
         bridges: Enum.map(owned_bridges, & &1["id"]),
         all_channel_ids: Enum.map(channels, & &1["id"]),
         all_bridge_ids: Enum.map(bridges, & &1["id"])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp valid_cleanup_bindings?(saved, holding, consult, destination_bridge) when is_map(saved) do
    map_size(saved) == 0 or
      (safe_id?(saved["external"]) and
         (is_nil(saved["app"]) or safe_id?(saved["app"])) and
         (is_nil(saved["mixing"]) or safe_id?(saved["mixing"])) and
         saved["holding"] == holding and saved["consult"] == consult and
         (is_nil(saved["destination_bridge"]) or saved["destination_bridge"] == destination_bridge))
  end

  defp valid_cleanup_bindings?(_, _, _, _), do: false

  defp safe_cleanup_channels?(owned, channels, command, saved, consult) do
    roles = %{"external" => saved["external"], "app" => saved["app"], "consult" => consult}

    relevant =
      Enum.filter(channels, fn channel ->
        channel["id"] in [saved["external"], saved["app"], consult] or
          get_in(channel, ["channelvars", "KC_CALL_ID"]) == command.call_id
      end)

    Enum.all?(relevant, &bound?(&1, command)) and
      Enum.all?(owned, fn channel ->
        role = get_in(channel, ["channelvars", "KC_ROLE"])

        safe_id?(channel["id"]) and Map.has_key?(roles, role) and
          (is_nil(roles[role]) or roles[role] == channel["id"])
      end) and
      Enum.all?(Map.keys(roles), fn role ->
        Enum.count(owned, &(get_in(&1, ["channelvars", "KC_ROLE"]) == role)) <= 1
      end)
  end

  defp delete_owned_channels(ids, command, config, requester) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case call(:get, "/channels/" <> id, %{}, config, requester) do
        {:error, :not_found} ->
          {:cont, :ok}

        {:ok, channel} ->
          if channel["id"] == id and bound?(channel, command) and
               get_in(channel, ["channelvars", "KC_ROLE"]) in ["external", "app", "consult"] do
            case delete_channel(id, config, requester) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          else
            {:halt, {:error, :telephony_pbx_binding_invalid}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp delete_owned_bridges(ids, config, requester) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      # Re-read membership after hanging up: a foreign/new member never confers
      # permission to destroy a bridge, even when its ID was previously owned.
      case call(:get, "/bridges/" <> id, %{}, config, requester) do
        {:error, :not_found} ->
          {:cont, :ok}

        {:ok, %{"id" => ^id, "channels" => []}} ->
          case call(:delete, "/bridges/" <> id, %{}, config, requester) do
            {:ok, _} -> {:cont, :ok}
            {:error, :not_found} -> {:cont, :ok}
            error -> {:halt, error}
          end

        {:ok, _} ->
          {:halt, {:error, :telephony_pbx_binding_invalid}}

        error ->
          {:halt, error}
      end
    end)
  end

  def wait_in_queue(command, requester \\ &CommsIntegrations.PinnedHttp.request/5) do
    with true <- get_in(capabilities(), [:queues, :supported]) == true,
         {:ok, configured} <- configuration(),
         config =
           Map.put(configured, :control_deadline, System.monotonic_time(:millisecond) + 10_000),
         {:ok, channels} when is_list(channels) <- call(:get, "/channels", %{}, config, requester),
         true <- length(channels) <= 2_000,
         [external] <-
           Enum.filter(
             channels,
             &(bound?(&1, command) and get_in(&1, ["channelvars", "KC_ROLE"]) == "external")
           ),
         true <- safe_id?(external["id"]),
         holding = "kc_hold_" <> compact(command.call_id),
         :ok <- ensure_bridge(holding, "holding", external["id"], config, requester),
         :ok <- ensure_channel_in(external["id"], holding, config, requester),
         {:ok, _} <- call(:post, "/bridges/" <> holding <> "/moh", %{}, config, requester) do
      :ok
    else
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  def resume_route(command) do
    control = %CommsCore.Telephony.ControlRequest{
      command_id: command.call_id,
      call_id: command.call_id,
      tenant_id: command.tenant_id,
      action: :resume,
      provider_room: command.provider_room,
      provider_identity: command.provider_identity,
      destination: nil,
      pbx_state: %{},
      reconcile: true
    }

    case execute_control(control) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def verify_event(body, authorization)
      when is_binary(body) and byte_size(body) <= 262_144 and is_binary(authorization) do
    secret = Application.get_env(:comms_integrations, :telephony_pbx_webhook_secret)

    with true <- is_binary(secret) and byte_size(secret) >= 32,
         ["v1", timestamp, signature] <- String.split(authorization, ":"),
         {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - seconds) <= 300,
         {:ok, provided} <- Base.decode16(signature, case: :mixed),
         true <- byte_size(provided) == 32,
         actual = :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body),
         true <- secure_equal?(provided, actual),
         {:ok, %{"type" => "PlaybackFinished", "event_id" => id, "playback" => playback}} <-
           Jason.decode(body),
         true <- valid_text?(id) and is_map(playback),
         "kc_notice_" <> compact_id <- playback["id"],
         true <- Regex.match?(~r/^[0-9a-f]{32}$/, compact_id),
         "channel:" <> channel_id <- playback["target_uri"],
         true <-
           safe_id?(channel_id) and playback["state"] == "done" and
             is_binary(playback["media_uri"]) do
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = compact_id

      {:ok,
       %{
         event_id: id,
         call_id: Enum.join([a, b, c, d, e], "-"),
         channel_id: channel_id,
         playback_id: playback["id"],
         media_uri: playback["media_uri"]
       }}
    else
      _ -> {:error, :invalid_provider_webhook}
    end
  end

  def verify_event(_, _), do: {:error, :invalid_provider_webhook}

  defp secure_equal?(left, right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  def recording(request, requester \\ &CommsIntegrations.PinnedHttp.request/5) do
    with true <-
           is_binary(request.recording_name) and
             Regex.match?(~r/^kc_vm_[0-9a-f]{32}$/, request.recording_name),
         true <-
           request.operation == :delete or
             get_in(capabilities(), [:voicemail, :supported]) == true,
         {:ok, config} <-
           if(request.operation == :delete, do: control_configuration(), else: configuration()) do
      case request.operation do
        :delete ->
          delete_recording(request.recording_name, config, requester)

        operation when operation in [:playback, :reconcile] ->
          with {:ok, %{"name" => exact_name, "format" => "wav"}} <-
                 call(
                   :get,
                   "/recordings/stored/" <> request.recording_name,
                   %{},
                   config,
                   requester
                 ),
               true <- exact_name == request.recording_name,
               {:ok, bytes} <- recording_file(request.recording_name, config, requester),
               {:ok, duration} <- wav_duration(bytes) do
            if operation == :playback,
              do: {:ok, %{body: bytes, content_type: "audio/wav"}},
              else:
                {:ok,
                 %{
                   duration_seconds: duration,
                   body: bytes,
                   content_type: "audio/wav",
                   recording_name: request.recording_name
                 }}
          else
            {:error, _} = error -> error
            _ -> {:error, :invalid_voicemail_media}
          end

        _ ->
          {:error, :telephony_control_unsupported}
      end
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end

  defp delete_recording(name, config, requester) do
    config = Map.put(config, :control_deadline, System.monotonic_time(:millisecond) + 20_000)
    live = call(:delete, "/recordings/live/" <> name, %{}, config, requester)
    stored = call(:delete, "/recordings/stored/" <> name, %{}, config, requester)

    with true <- match?({:ok, _}, live) or live == {:error, :not_found},
         true <- match?({:ok, _}, stored) or stored == {:error, :not_found},
         {:error, :not_found} <- call(:get, "/recordings/live/" <> name, %{}, config, requester),
         {:error, :not_found} <- call(:get, "/recordings/stored/" <> name, %{}, config, requester) do
      :deleted
    else
      _ -> {:error, :voicemail_source_deletion_pending}
    end
  end

  defp recording_file(name, config, requester) do
    headers = [
      {"authorization", "Basic " <> Base.encode64(config.username <> ":" <> config.password)},
      {"accept", "audio/wav"}
    ]

    case requester.(
           :get,
           config.origin <> "/ari/recordings/stored/" <> name <> "/file",
           headers,
           "",
           allowed_hosts: [config.host],
           allowed_ports: [443],
           timeout_ms: 5_000,
           max_response_bytes: 8_388_608
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= 8_388_608 ->
        {:ok, body}

      _ ->
        {:error, :telephony_provider_unavailable}
    end
  end

  defp wav_duration(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>),
    do: wav_chunks(chunks, nil, 0)

  defp wav_duration(_), do: {:error, :invalid_voicemail_media}

  defp wav_chunks(<<"fmt ", size::little-32, body::binary>>, nil, count)
       when size >= 16 and size <= 128 and count < 64 and byte_size(body) >= size do
    <<format::little-16, channels::little-16, rate::little-32, byte_rate::little-32,
      _align::little-16, bits::little-16, _::binary>> = binary_part(body, 0, size)

    if format == 1 and channels in [1, 2] and rate in [8_000, 16_000, 24_000, 48_000] and
         bits == 16 and byte_rate == rate * channels * 2,
       do: wav_chunks(drop_chunk(body, size), byte_rate, count + 1),
       else: {:error, :invalid_voicemail_media}
  end

  defp wav_chunks(<<"data", size::little-32, body::binary>>, byte_rate, _count)
       when is_integer(byte_rate) and byte_size(body) >= size do
    seconds = div(size + byte_rate - 1, byte_rate)
    if seconds in 1..120, do: {:ok, seconds}, else: {:error, :invalid_voicemail_media}
  end

  defp wav_chunks(<<_kind::binary-size(4), size::little-32, body::binary>>, rate, count)
       when count < 64 and byte_size(body) >= size,
       do: wav_chunks(drop_chunk(body, size), rate, count + 1)

  defp wav_chunks(_, _, _), do: {:error, :invalid_voicemail_media}

  defp drop_chunk(body, size) do
    offset = size + rem(size, 2)

    if byte_size(body) >= offset,
      do: binary_part(body, offset, byte_size(body) - offset),
      else: <<>>
  end

  def prepare_control(command),
    do: prepare_control(command, &CommsIntegrations.PinnedHttp.request/5)

  def prepare_control(%{action: :blind_transfer}, _requester), do: {:ok, nil}

  def prepare_control(command, requester) do
    with true <- get_in(capabilities(), [command.action, :supported]) == true,
         {:ok, config} <- configuration() do
      bindings(command, config, requester)
    else
      _ -> {:error, :telephony_control_unsupported}
    end
  end

  def configuration(), do: configuration(false)
  def control_configuration(), do: configuration(true)

  defp configuration(allow_disabled) do
    origin = Application.get_env(:comms_integrations, :telephony_pbx_api_url)
    username = Application.get_env(:comms_integrations, :telephony_pbx_username)
    password = Application.get_env(:comms_integrations, :telephony_pbx_password)
    endpoint = Application.get_env(:comms_integrations, :telephony_pbx_endpoint)
    app = Application.get_env(:comms_integrations, :telephony_pbx_application, "k-comms")
    uri = if is_binary(origin), do: URI.parse(origin), else: %URI{}

    dns =
      is_binary(uri.host) and
        match?({:error, _}, :inet.parse_address(String.to_charlist(uri.host)))

    if (allow_disabled or
          Application.get_env(:comms_integrations, :telephony_pbx_enabled, false) == true) and
         uri.scheme == "https" and uri.port == 443 and dns and uri.path in [nil, "", "/"] and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         valid_text?(username) and valid_text?(password) and byte_size(password) >= 24 and
         is_binary(endpoint) and Regex.match?(~r/^[A-Za-z0-9_-]{1,100}$/, endpoint) and
         is_binary(app) and Regex.match?(~r/^[A-Za-z0-9_-]{1,100}$/, app) do
      {:ok,
       %{
         origin: String.trim_trailing(origin, "/"),
         host: uri.host,
         username: username,
         password: password,
         endpoint: endpoint,
         app: app
       }}
    else
      {:error, :telephony_provider_unavailable}
    end
  end

  defp bindings(%{system: true, action: :voicemail} = command, config, requester) do
    with {:ok, channels} when is_list(channels) <- call(:get, "/channels", %{}, config, requester),
         true <- length(channels) <= 2_000,
         [external] <-
           Enum.filter(
             channels,
             &(bound?(&1, command) and get_in(&1, ["channelvars", "KC_ROLE"]) == "external")
           ),
         true <- safe_id?(external["id"]),
         apps <-
           Enum.filter(
             channels,
             &(bound?(&1, command) and get_in(&1, ["channelvars", "KC_ROLE"]) == "app")
           ),
         true <- length(apps) <= 1 do
      holding = "kc_hold_" <> compact(command.call_id)

      app_id =
        case apps do
          [app] -> app["id"]
          [] -> Map.get(command.pbx_state || %{}, "app")
        end

      saved = command.pbx_state || %{}

      cond do
        not is_nil(app_id) and not safe_id?(app_id) ->
          {:error, :telephony_pbx_binding_invalid}

        not is_nil(saved["destination_bridge"]) ->
          # IVR has already persisted exact caller/app/original bridge handles.
          # Voicemail uses holding for its separate notice/capture, but must
          # preserve those frozen handles for bind equality and final cleanup.
          if map_size(saved) == 7 and saved["external"] == external["id"] and
               saved["app"] == app_id and
               safe_id?(saved["mixing"]) and
               saved["recording"] == "kc_vm_" <> compact(command.call_id) and
               valid_cleanup_bindings?(
                 saved,
                 holding,
                 "kc_consult_" <> compact(command.call_id),
                 "kc_ivr_mix_" <> compact(command.call_id)
               ), do: {:ok, saved}, else: {:error, :telephony_pbx_binding_invalid}

        true ->
          {:ok,
           %{
             "external" => external["id"],
             "app" => app_id,
             "mixing" => holding,
             "holding" => holding,
             "consult" => "kc_consult_" <> compact(command.call_id),
             "recording" => "kc_vm_" <> compact(command.call_id)
           }}
      end
    else
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp bindings(%{pbx_state: saved} = command, config, requester) when map_size(saved) > 0 do
    with true <-
           Enum.all?(
             ["external", "app", "mixing", "holding", "consult", "recording"],
             &safe_id?(saved[&1])
           ),
         {:ok, external} <- call(:get, "/channels/" <> saved["external"], %{}, config, requester),
         true <-
           bound?(external, command) and
             get_in(external, ["channelvars", "KC_ROLE"]) == "external",
         {:ok, app} <- saved_app(command, saved, config, requester),
         true <- bound?(app, command) and get_in(app, ["channelvars", "KC_ROLE"]) == "app",
         {:ok, %{"bridge_type" => "mixing"} = bridge} <-
           call(:get, "/bridges/" <> saved["mixing"], %{}, config, requester),
         {:ok, channels} when is_list(channels) <- call(:get, "/channels", %{}, config, requester),
         true <- length(channels) <= 2_000,
         true <- safe_mixing?(bridge, channels, command, saved["external"], saved["app"]) do
      {:ok, saved}
    else
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp bindings(command, config, requester) do
    with {:ok, channels} when is_list(channels) <- call(:get, "/channels", %{}, config, requester),
         true <- length(channels) <= 2_000,
         matches <- Enum.filter(channels, &bound?(&1, command)),
         [external] <-
           Enum.filter(matches, &(get_in(&1, ["channelvars", "KC_ROLE"]) == "external")),
         [app] <- Enum.filter(matches, &(get_in(&1, ["channelvars", "KC_ROLE"]) == "app")),
         true <- safe_id?(external["id"]) and safe_id?(app["id"]),
         {:ok, bridges} when is_list(bridges) <- call(:get, "/bridges", %{}, config, requester),
         true <- length(bridges) <= 2_000,
         [mixing] <-
           Enum.filter(
             bridges,
             &(&1["bridge_type"] == "mixing" and app["id"] in (&1["channels"] || []))
           ),
         true <- safe_id?(mixing["id"]),
         true <- safe_mixing?(mixing, channels, command, external["id"], app["id"]) do
      {:ok,
       %{
         "external" => external["id"],
         "app" => app["id"],
         "mixing" => mixing["id"],
         "holding" => "kc_hold_" <> compact(command.call_id),
         "consult" => "kc_consult_" <> compact(command.call_id),
         "recording" => "kc_vm_" <> compact(command.call_id)
       }}
    else
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp saved_app(command, saved, config, requester) do
    case call(:get, "/channels/" <> saved["app"], %{}, config, requester) do
      {:error, :not_found}
      when command.reconcile == true and command.action in [:complete_transfer, :voicemail] ->
        # Completion can legitimately destroy the app leg. The persisted binding
        # and exact external leg still establish ownership; never substitute IDs.
        {:ok,
         %{
           "channelvars" => %{
             "KC_TENANT_ID" => command.tenant_id,
             "KC_CALL_ID" => command.call_id,
             "KC_LIVEKIT_ROOM" => command.provider_room,
             "KC_SIP_IDENTITY" => command.provider_identity,
             "KC_ROLE" => "app"
           }
         }}

      result ->
        result
    end
  end

  defp safe_mixing?(bridge, channels, command, external, app) do
    roles = %{
      external => "external",
      app => "app",
      ("kc_consult_" <> compact(command.call_id)) => "consult"
    }

    Enum.all?(bridge["channels"] || [], fn id ->
      Map.has_key?(roles, id) and
        case Enum.find(channels, &(&1["id"] == id)) do
          nil ->
            false

          channel ->
            bound?(channel, command) and get_in(channel, ["channelvars", "KC_ROLE"]) == roles[id]
        end
    end)
  end

  defp bound?(channel, command) when is_map(channel) do
    vars = channel["channelvars"] || %{}

    is_map(vars) and vars["KC_TENANT_ID"] == command.tenant_id and
      vars["KC_CALL_ID"] == command.call_id and vars["KC_LIVEKIT_ROOM"] == command.provider_room and
      vars["KC_SIP_IDENTITY"] == command.provider_identity
  end

  defp bound?(_, _), do: false

  defp execute(%{action: :hold}, b, c, r) do
    with :ok <- hold(b, c, r), do: {:ok, "held"}
  end

  defp execute(%{action: :resume}, b, c, r) do
    with :ok <- resume(b, c, r), do: {:ok, "connected"}
  end

  defp execute(%{action: :consult_transfer} = command, b, c, r) do
    with :ok <- authorize_destination(command.destination),
         :ok <- hold(b, c, r),
         :ok <- ensure_consult(command, b, c, r),
         :ok <- ensure_channel_in(b["consult"], b["mixing"], c, r) do
      {:ok, "consulting"}
    end
  end

  defp execute(%{action: :cancel_transfer} = command, b, c, r) do
    with :ok <- cancel_consult(command, b, c, r), :ok <- resume(b, c, r), do: {:ok, "connected"}
  end

  defp execute(%{action: :complete_transfer} = command, b, c, r) do
    with {:ok, %{"state" => "Up"} = consult} <-
           call(:get, "/channels/" <> b["consult"], %{}, c, r),
         true <-
           bound?(consult, command) and get_in(consult, ["channelvars", "KC_ROLE"]) == "consult",
         :ok <- ensure_channel_in(b["external"], b["mixing"], c, r),
         :ok <- stop_moh(b["holding"], c, r),
         :ok <- delete_channel(b["app"], c, r) do
      {:ok, "transferred"}
    else
      _ -> {:error, :telephony_consultation_not_answered}
    end
  end

  defp execute(%{action: :voicemail} = command, b, c, r) do
    with :ok <- ensure_bridge(b["holding"], "holding", b["external"], c, r),
         :ok <- ensure_channel_in(b["external"], b["holding"], c, r),
         :ok <- stop_moh(b["holding"], c, r),
         :ok <- ensure_notice(command, b, c, r),
         :ok <- ensure_unbridged(b["external"], c, r),
         :ok <- ensure_recording(command, b, c, r),
         :ok <- delete_app(b["app"], c, r) do
      {:ok, "voicemail"}
    end
  end

  defp execute(_, _, _, _), do: {:error, :telephony_control_unsupported}

  defp cancel_consult(command, b, c, r) do
    case call(:get, "/channels/" <> b["consult"], %{}, c, r) do
      {:error, :not_found} ->
        :ok

      {:ok, channel} ->
        if bound?(channel, command) and get_in(channel, ["channelvars", "KC_ROLE"]) == "consult",
          do: delete_channel(b["consult"], c, r),
          else: {:error, :telephony_pbx_binding_invalid}

      error ->
        error
    end
  end

  defp hold(b, c, r) do
    with :ok <- ensure_bridge(b["holding"], "holding", b["external"], c, r),
         :ok <- ensure_channel_in(b["external"], b["holding"], c, r),
         {:ok, _} <- call(:post, "/bridges/" <> b["holding"] <> "/moh", %{}, c, r),
         do: :ok
  end

  defp resume(b, c, r) do
    with :ok <- ensure_channel_in(b["external"], b["mixing"], c, r),
         :ok <- stop_moh(b["holding"], c, r),
         do: :ok
  end

  defp stop_moh(id, c, r) do
    case call(:delete, "/bridges/" <> id <> "/moh", %{}, c, r) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp ensure_bridge(id, type, external, c, r) do
    case call(:get, "/bridges/" <> id, %{}, c, r) do
      {:ok, %{"bridge_type" => ^type} = bridge} ->
        if Enum.all?(bridge["channels"] || [], &(&1 == external)),
          do: :ok,
          else: {:error, :telephony_pbx_binding_invalid}

      {:error, :not_found} ->
        case call(:post, "/bridges/" <> id, %{type: type, name: id}, c, r) do
          {:ok, _} -> :ok
          error -> error
        end

      _ ->
        {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp ensure_channel_in(channel, bridge, c, r) do
    with {:ok, bridges} when is_list(bridges) <- call(:get, "/bridges", %{}, c, r) do
      target = Enum.find(bridges, &(&1["id"] == bridge))

      cond do
        is_nil(target) ->
          {:error, :telephony_pbx_binding_invalid}

        channel in (target["channels"] || []) ->
          :ok

        true ->
          current = Enum.filter(bridges, &(channel in (&1["channels"] || [])))

          result =
            Enum.reduce_while(current, :ok, fn existing, _ ->
              if safe_id?(existing["id"]) do
                case call(
                       :post,
                       "/bridges/" <> existing["id"] <> "/removeChannel",
                       %{channel: channel},
                       c,
                       r
                     ) do
                  {:ok, _} -> {:cont, :ok}
                  error -> {:halt, error}
                end
              else
                {:halt, {:error, :telephony_pbx_binding_invalid}}
              end
            end)

          with :ok <- result,
               {:ok, _} <-
                 call(:post, "/bridges/" <> bridge <> "/addChannel", %{channel: channel}, c, r),
               do: :ok
      end
    end
  end

  defp ensure_unbridged(channel, c, r) do
    with {:ok, bridges} when is_list(bridges) <- call(:get, "/bridges", %{}, c, r) do
      bridges
      |> Enum.filter(&(channel in (&1["channels"] || [])))
      |> Enum.reduce_while(:ok, fn bridge, _ ->
        if safe_id?(bridge["id"]) do
          case call(
                 :post,
                 "/bridges/" <> bridge["id"] <> "/removeChannel",
                 %{channel: channel},
                 c,
                 r
               ) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end
        else
          {:halt, {:error, :telephony_pbx_binding_invalid}}
        end
      end)
    end
  end

  defp ensure_consult(command, b, c, r) do
    case call(:get, "/channels/" <> b["consult"], %{}, c, r) do
      {:ok, channel} ->
        if bound?(channel, command) and get_in(channel, ["channelvars", "KC_ROLE"]) == "consult" and
             channel["state"] == "Up", do: :ok, else: {:error, :telephony_consultation_pending}

      {:error, :not_found} when command.reconcile == true ->
        {:error, :telephony_outcome_unknown}

      {:error, :not_found} ->
        duration =
          if command.call_expires_at,
            do:
              DateTime.diff(command.call_expires_at, DateTime.utc_now(), :second)
              |> max(1)
              |> min(14_400),
            else: 1_800

        variables = %{
          "KC_TENANT_ID" => command.tenant_id,
          "KC_CALL_ID" => command.call_id,
          "KC_LIVEKIT_ROOM" => command.provider_room,
          "KC_SIP_IDENTITY" => command.provider_identity,
          "KC_ROLE" => "consult",
          "TIMEOUT(absolute)" => Integer.to_string(duration)
        }

        case call(
               :post,
               "/channels",
               %{
                 channelId: b["consult"],
                 endpoint: "PJSIP/" <> command.destination <> "@" <> c.endpoint,
                 app: c.app,
                 timeout: 30,
                 variables: variables
               },
               c,
               r
             ) do
          {:ok, _} -> {:error, :telephony_consultation_pending}
          _ -> {:error, :telephony_outcome_unknown}
        end

      error ->
        error
    end
  end

  defp ensure_notice(%{notice_completed_at: completed}, _b, _c, _r) when not is_nil(completed),
    do: :ok

  defp ensure_notice(command, b, c, r) do
    notice = command.notice_media
    playback = "kc_notice_" <> compact(command.call_id)

    if not is_binary(notice) or not Regex.match?(~r|^sound:[A-Za-z0-9_/-]{1,150}$|, notice) do
      {:error, :telephony_mailbox_notice_required}
    else
      case call(:get, "/playbacks/" <> playback, %{}, c, r) do
        {:ok, _} ->
          {:error, :telephony_notice_pending}

        {:error, :not_found} when command.reconcile == true ->
          {:error, :telephony_notice_pending}

        {:error, :not_found} ->
          case call(
                 :post,
                 "/channels/" <> b["external"] <> "/play/" <> playback,
                 %{media: notice},
                 c,
                 r
               ) do
            {:ok, _} -> {:error, :telephony_notice_pending}
            error -> error
          end

        error ->
          error
      end
    end
  end

  defp ensure_recording(command, b, c, r) do
    case call(:get, "/recordings/live/" <> b["recording"], %{}, c, r) do
      {:ok, %{"name" => name}} ->
        if name == b["recording"], do: :ok, else: {:error, :telephony_pbx_binding_invalid}

      {:error, :not_found} when command.reconcile == true ->
        {:error, :telephony_outcome_unknown}

      {:error, :not_found} ->
        case call(
               :post,
               "/channels/" <> b["external"] <> "/record",
               %{
                 name: b["recording"],
                 format: "wav",
                 maxDurationSeconds: 120,
                 maxSilenceSeconds: 10,
                 ifExists: "fail",
                 beep: true,
                 terminateOn: "#"
               },
               c,
               r
             ) do
          {:ok, _} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp delete_app(nil, _c, _r), do: :ok
  defp delete_app(id, c, r), do: delete_channel(id, c, r)

  defp delete_channel(id, c, r) do
    case call(:delete, "/channels/" <> id, %{}, c, r) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp call(method, path, params, config, requester) do
    remaining =
      Map.get(config, :control_deadline, System.monotonic_time(:millisecond) + 5_000) -
        System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :telephony_outcome_unknown}
    else
      call_with_timeout(method, path, params, config, requester, min(remaining, 5_000))
    end
  end

  defp call_with_timeout(method, path, params, config, requester, timeout) do
    {variables, query} = Map.pop(params, :variables)

    query =
      query |> Enum.map(fn {k, v} -> {Atom.to_string(k), to_string(v)} end) |> URI.encode_query()

    url = config.origin <> "/ari" <> path <> if(query == "", do: "", else: "?" <> query)

    headers = [
      {"authorization", "Basic " <> Base.encode64(config.username <> ":" <> config.password)},
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]

    body = if variables, do: Jason.encode!(%{variables: variables}), else: ""

    case requester.(method, url, headers, body,
           allowed_hosts: [config.host],
           allowed_ports: [443],
           timeout_ms: timeout,
           max_response_bytes: 262_144
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        if response in [nil, ""], do: {:ok, %{}}, else: Jason.decode(response)

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      _ ->
        {:error, :telephony_outcome_unknown}
    end
  rescue
    _ -> {:error, :telephony_outcome_unknown}
  end

  defp safe_id?(id), do: is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_.:-]{1,200}$/, id)

  defp valid_text?(text),
    do: is_binary(text) and byte_size(text) in 1..255 and String.trim(text) != ""

  defp compact(id), do: String.replace(id, "-", "")
end
