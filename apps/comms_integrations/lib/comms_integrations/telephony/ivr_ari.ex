defmodule CommsIntegrations.Telephony.IvrARI do
  @moduledoc "Qualified caller-only ARI menu playback and once-claimed destination legs."
  @behaviour CommsCore.Telephony.IvrProviderPort.Contract
  alias CommsCore.Telephony.{IvrEvent, IvrProviderRequest}
  alias CommsIntegrations.Telephony.AsteriskARI
  @max_body 262_144
  @max_resources 2_000

  @impl true
  def ready? do
    Application.get_env(:comms_integrations, :telephony_ivr_qualified, false) == true and
      Application.get_env(:comms_integrations, :telephony_pbx_qualified, false) == true and
      match?({:ok, _}, AsteriskARI.configuration()) and
      valid_allowlist?()
  end

  @impl true
  def prepare(request), do: prepare(request, &CommsIntegrations.PinnedHttp.request/5)
  def prepare(%IvrProviderRequest{} = request, requester) do
    with :ok <- admissible(request), {:ok, config} <- configuration(request),
         {:ok, channels} <- resources("/channels", config, requester),
         [external] <- Enum.filter(channels, &(bound?(&1, request, "external"))),
         apps <- Enum.filter(channels, &(bound?(&1, request, "app"))),
         true <- length(apps) <= 1,
         app_id = (case apps do [app] -> app["id"]; [] -> nil end),
         {:ok, bridges} <- resources("/bridges", config, requester),
         {:ok, mixing} <- original_mixing(bridges, external["id"], app_id, request.call_id),
         true <- safe_id?(external["id"]) and (is_nil(app_id) or safe_id?(app_id)),
         true <- all_call_channels?(channels, request, external["id"], app_id),
         true <- safe_membership?(bridges, external["id"], app_id, nil) do
      {:ok, %{"external" => external["id"], "app" => app_id, "mixing" => mixing,
        "holding" => "kc_hold_" <> compact(request.call_id),
        "consult" => "kc_consult_" <> compact(request.call_id),
        "recording" => "kc_vm_" <> compact(request.call_id),
        "destination_bridge" => "kc_ivr_mix_" <> compact(request.call_id)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  @impl true
  def play(request), do: play(request, &CommsIntegrations.PinnedHttp.request/5)
  def play(%IvrProviderRequest{} = request, requester) do
    with :ok <- admissible(request), {:ok, config} <- configuration(request),
         :ok <- saved_resources(request, config, requester, false) do
      if request.reconcile do
        observe_playback(request, config, requester)
      else
        with :ok <- set_caller_vars(request, config, requester),
             :ok <- isolate_caller(request, config, requester),
             :ok <- ensure_answered(request, config, requester),
             {:ok, _} <- api(:post, "/channels/" <> request.bindings["external"] <> "/play/" <> request.playback_id,
               %{media: request.prompt_media}, config, requester, request) do
          {:ok, :pending}
        else
          {:error, _} = error -> error
          _ -> {:error, :telephony_outcome_unknown}
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  @impl true
  def destination(request), do: destination(request, &CommsIntegrations.PinnedHttp.request/5)
  def destination(%IvrProviderRequest{} = request, requester) do
    with :ok <- admissible(request),
         :ok <- AsteriskARI.authorize_destination(request.destination),
         {:ok, config} <- configuration(request),
         :ok <- saved_resources(request, config, requester, true) do
      case {request.stage, request.reconcile} do
        {:originate, false} -> originate(request, config, requester)
        {:originate, true} -> observe_destination(request, config, requester)
        {:connect, false} -> connect_destination(request, config, requester)
        {:connect, true} -> observe_connection(request, config, requester)
        _ -> {:error, :invalid_telephony_command}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  @impl true
  def verify_event(body, authorization)
      when is_binary(body) and byte_size(body) <= @max_body and is_binary(authorization) do
    secret = Application.get_env(:comms_integrations, :telephony_pbx_webhook_secret)
    with true <- is_binary(secret) and byte_size(secret) >= 32,
         ["v1", timestamp, signature] <- String.split(authorization, ":"),
         {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - seconds) <= 300,
         {:ok, provided} <- Base.decode16(signature, case: :mixed),
         true <- byte_size(provided) == 32,
         expected = :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body),
         true <- secure_equal?(provided, expected),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, event} <- normalize_event(decoded),
         fingerprint = :crypto.mac(:hmac, :sha256, secret, "k-comms:ivr-event:v1\0" <> body) |> Base.encode16(case: :lower) do
      {:ok, %{event | body_fingerprint: fingerprint}}
    else
      _ -> {:error, :invalid_provider_webhook}
    end
  end
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}

  def normalize_event(%{"type" => "ChannelDtmfReceived", "event_id" => event_id,
      "timestamp" => timestamp, "digit" => digit, "channel" => channel}) do
    vars = if is_map(channel), do: channel["channelvars"], else: nil
    with true <- receipt_id?(event_id) and is_map(channel) and is_map(vars),
         true <- vars["KC_ROLE"] == "external" and safe_id?(channel["id"]),
         true <- digit in ~w(0 1 2 3 4 5 6 7 8 9 * # A B C D),
         {:ok, tenant_id} <- Ecto.UUID.cast(vars["KC_TENANT_ID"]),
         {:ok, call_id} <- Ecto.UUID.cast(vars["KC_CALL_ID"]),
         {:ok, run_id} <- Ecto.UUID.cast(vars["KC_IVR_RUN_ID"]),
         {:ok, step} <- step(vars["KC_IVR_STEP"]),
         true <- valid_text?(vars["KC_LIVEKIT_ROOM"]) and valid_text?(vars["KC_SIP_IDENTITY"]),
         true <- is_binary(timestamp), {:ok, occurred_at, _} <- DateTime.from_iso8601(timestamp) do
      {:ok, %IvrEvent{event_id: event_id, body_fingerprint: "", type: :digit,
        tenant_id: tenant_id, call_id: call_id, run_id: run_id, step: step,
        channel_id: channel["id"], provider_room: vars["KC_LIVEKIT_ROOM"],
        provider_identity: vars["KC_SIP_IDENTITY"], occurred_at: occurred_at, digit: digit}}
    else
      _ -> {:error, :invalid_provider_event}
    end
  end
  def normalize_event(%{"type" => "PlaybackFinished", "event_id" => event_id,
      "timestamp" => timestamp, "playback" => playback}) do
    with true <- receipt_id?(event_id) and is_map(playback),
         true <- playback["state"] == "done",
         {:ok, run_id, step} <- playback_identity(playback["id"]),
         "channel:" <> channel_id <- playback["target_uri"],
         true <- safe_id?(channel_id) and approved_prompt?(playback["media_uri"]),
         true <- is_binary(timestamp), {:ok, occurred_at, _} <- DateTime.from_iso8601(timestamp) do
      {:ok, %IvrEvent{event_id: event_id, body_fingerprint: "", type: :playback_finished,
        run_id: run_id, step: step, channel_id: channel_id, occurred_at: occurred_at,
        playback_id: playback["id"], media_uri: playback["media_uri"]}}
    else
      _ -> {:error, :invalid_provider_event}
    end
  end
  def normalize_event(_), do: {:error, :invalid_provider_event}

  defp admissible(request) do
    if ready?() and uuid?(request.run_id) and uuid?(request.call_id) and uuid?(request.tenant_id) and
         request.step in 1..3 and request.playback_id == "kc_ivr_" <> compact(request.run_id) <> "_" <> Integer.to_string(request.step) and
         valid_text?(request.provider_room) and valid_text?(request.provider_identity) and
         approved_prompt?(request.prompt_media) and is_map(request.bindings) and
         is_boolean(request.reconcile) and request.stage in [:originate, :connect] and
         match?(%DateTime{}, request.expires_at) and is_integer(request.effect_deadline_ms) and
         DateTime.compare(request.expires_at, now()) == :gt and
         request.effect_deadline_ms > System.monotonic_time(:millisecond), do: :ok,
      else: {:error, :telephony_ivr_unavailable}
  end

  defp configuration(request) do
    with {:ok, config} <- AsteriskARI.configuration() do
      {:ok, Map.put(config, :deadline, min(request.effect_deadline_ms,
        System.monotonic_time(:millisecond) + 10_000))}
    end
  end

  defp saved_resources(request, config, requester, allow_consult?) do
    b = request.bindings
    with true <- valid_bindings?(b, request),
         {:ok, channels} <- resources("/channels", config, requester),
         true <- Enum.count(channels, &(bound?(&1, request, "external") and &1["id"] == b["external"])) == 1,
         true <- is_nil(b["app"]) or Enum.count(channels, &(bound?(&1, request, "app") and &1["id"] == b["app"])) == 1,
         true <- all_call_channels?(channels, request, b["external"], b["app"], if(allow_consult?, do: b["consult"], else: nil)),
         {:ok, bridges} <- resources("/bridges", config, requester),
         true <- safe_membership?(bridges, b["external"], b["app"], if(allow_consult?, do: b["consult"], else: nil)) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp valid_bindings?(b, request) do
    is_map(b) and map_size(b) == 7 and safe_id?(b["external"]) and safe_id?(b["mixing"]) and
      (is_nil(b["app"]) or safe_id?(b["app"])) and
      b["holding"] == "kc_hold_" <> compact(request.call_id) and
      b["consult"] == "kc_consult_" <> compact(request.call_id) and
      b["recording"] == "kc_vm_" <> compact(request.call_id) and
      b["destination_bridge"] == "kc_ivr_mix_" <> compact(request.call_id)
  end

  defp original_mixing(bridges, external, nil, call_id) do
    case Enum.filter(bridges, &(external in (&1["channels"] || []))) do
      [] -> {:ok, "kc_hold_" <> compact(call_id)}
      [%{"id" => id, "bridge_type" => type}] when type in ["holding", "mixing"] -> {:ok, id}
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end
  defp original_mixing(bridges, _external, app, _call_id) do
    case Enum.filter(bridges, &(&1["bridge_type"] == "mixing" and app in (&1["channels"] || []))) do
      [%{"id" => id}] -> {:ok, id}
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp all_call_channels?(channels, request, external, app, consult \\ nil) do
    roles = %{"external" => external, "app" => app, "consult" => consult}
    relevant = Enum.filter(channels, fn channel ->
      channel["id"] in [external, app, consult] or get_in(channel, ["channelvars", "KC_CALL_ID"]) == request.call_id
    end)
    Enum.all?(relevant, fn channel ->
      role = get_in(channel, ["channelvars", "KC_ROLE"])
      Map.has_key?(roles, role) and not is_nil(roles[role]) and channel["id"] == roles[role] and bound?(channel, request, role)
    end) and Enum.all?(Map.keys(roles), fn role ->
      Enum.count(relevant, &(get_in(&1, ["channelvars", "KC_ROLE"]) == role)) <= 1
    end)
  end

  defp safe_membership?(bridges, external, app, consult) do
    allowed = Enum.reject([external, app, consult], &is_nil/1)
    Enum.all?(bridges, fn bridge ->
      members = bridge["channels"] || []
      if Enum.any?(members, &(&1 in allowed)) do
        bridge["bridge_type"] in ["holding", "mixing"] and length(members) <= 3 and
          Enum.all?(members, &(&1 in allowed))
      else
        true
      end
    end)
  end

  defp set_caller_vars(request, config, requester) do
    Enum.reduce_while([{"KC_IVR_RUN_ID", request.run_id}, {"KC_IVR_STEP", Integer.to_string(request.step)}], :ok,
      fn {variable, value}, :ok ->
        case api(:post, "/channels/" <> request.bindings["external"] <> "/variable",
          %{variable: variable, value: value}, config, requester, request) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
  end

  defp isolate_caller(request, config, requester) do
    b = request.bindings
    with :ok <- ensure_bridge(b["holding"], "holding", [b["external"]], config, requester, request),
         :ok <- move_channel(b["external"], b["holding"], request, config, requester),
         {:ok, _} <- api(:delete, "/bridges/" <> b["holding"] <> "/moh", %{}, config, requester, request) do
      :ok
    end
  end

  defp ensure_answered(request, config, requester) do
    path = "/channels/" <> request.bindings["external"]
    with {:ok, caller} <- api(:get, path, %{}, config, requester), true <- bound?(caller, request, "external") do
      if caller["state"] == "Up" do
        :ok
      else
        with {:ok, _} <- api(:post, path <> "/answer", %{}, config, requester, request),
             {:ok, observed} <- api(:get, path, %{}, config, requester),
             true <- bound?(observed, request, "external") and observed["state"] == "Up" do
          :ok
        else
          _ -> {:error, :telephony_outcome_unknown}
        end
      end
    else
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp observe_playback(request, config, requester) do
    case api(:get, "/playbacks/" <> request.playback_id, %{}, config, requester) do
      {:ok, playback} ->
        if playback["id"] == request.playback_id and
             playback["target_uri"] == "channel:" <> request.bindings["external"] and
             playback["media_uri"] == request.prompt_media do
          case playback["state"] do
            "done" -> {:ok, :completed}
            state when state in ["queued", "playing", "continuing", "paused"] -> {:ok, :pending}
            _ -> {:error, :telephony_outcome_unknown}
          end
        else
          {:error, :telephony_pbx_binding_invalid}
        end
      _ -> {:error, :telephony_outcome_unknown}
    end
  end

  defp originate(request, config, requester) do
    path = "/channels/" <> request.bindings["consult"]
    case api(:get, path, %{}, config, requester) do
      {:ok, channel} ->
        if bound?(channel, request, "consult"), do: observe_destination(request, config, requester),
          else: {:error, :telephony_pbx_binding_invalid}
      {:error, :not_found} ->
        seconds = max(1, min(30, DateTime.diff(request.expires_at, now(), :second)))
        variables = %{"KC_TENANT_ID" => request.tenant_id, "KC_CALL_ID" => request.call_id,
          "KC_LIVEKIT_ROOM" => request.provider_room, "KC_SIP_IDENTITY" => request.provider_identity,
          "KC_ROLE" => "consult", "TIMEOUT(absolute)" => Integer.to_string(seconds)}
        case api(:post, "/channels", %{channelId: request.bindings["consult"],
            endpoint: "PJSIP/" <> request.destination <> "@" <> config.endpoint,
            app: config.app, timeout: seconds, variables: variables}, config, requester, request) do
          {:ok, _} -> {:ok, :pending}
          _ -> {:error, :telephony_outcome_unknown}
        end
      _ -> {:error, :telephony_outcome_unknown}
    end
  end

  defp observe_destination(request, config, requester) do
    case api(:get, "/channels/" <> request.bindings["consult"], %{}, config, requester) do
      {:ok, channel} ->
        cond do
          not bound?(channel, request, "consult") -> {:error, :telephony_pbx_binding_invalid}
          channel["state"] == "Up" -> {:ok, :ready}
          true -> {:ok, :pending}
        end
      _ -> {:error, :telephony_outcome_unknown}
    end
  end

  defp connect_destination(request, config, requester) do
    b = request.bindings
    with {:ok, :ready} <- observe_destination(request, config, requester),
         {:ok, caller} <- api(:get, "/channels/" <> b["external"], %{}, config, requester),
         true <- bound?(caller, request, "external") and caller["state"] == "Up",
         :ok <- ensure_bridge(b["destination_bridge"], "mixing", [b["external"], b["consult"]], config, requester, request),
         :ok <- move_channel(b["external"], b["destination_bridge"], request, config, requester),
         :ok <- move_channel(b["consult"], b["destination_bridge"], request, config, requester) do
      observe_connection(request, config, requester)
    else
      {:error, _} = error -> error
      _ -> {:error, :telephony_outcome_unknown}
    end
  end

  defp observe_connection(request, config, requester) do
    b = request.bindings
    with {:ok, :ready} <- observe_destination(request, config, requester),
         {:ok, caller} <- api(:get, "/channels/" <> b["external"], %{}, config, requester),
         true <- bound?(caller, request, "external") and caller["state"] == "Up",
         {:ok, bridge} <- api(:get, "/bridges/" <> b["destination_bridge"], %{}, config, requester),
         true <- bridge["id"] == b["destination_bridge"] and bridge["bridge_type"] == "mixing" and
           Enum.sort(bridge["channels"] || []) == Enum.sort([b["external"], b["consult"]]) do
      {:ok, :connected}
    else
      _ -> {:error, :telephony_outcome_unknown}
    end
  end

  defp ensure_bridge(id, type, allowed, config, requester, request) do
    case api(:get, "/bridges/" <> id, %{}, config, requester) do
      {:ok, bridge} ->
        if bridge["id"] == id and bridge["bridge_type"] == type and
             Enum.all?(bridge["channels"] || [], &(&1 in allowed)), do: :ok,
          else: {:error, :telephony_pbx_binding_invalid}
      {:error, :not_found} ->
        with {:ok, _} <- api(:post, "/bridges/" <> id, %{type: type, name: id}, config, requester, request),
             {:ok, bridge} <- api(:get, "/bridges/" <> id, %{}, config, requester),
             true <- bridge["id"] == id and bridge["bridge_type"] == type and bridge["channels"] == [] do
          :ok
        else
          _ -> {:error, :telephony_pbx_binding_invalid}
        end
      error -> error
    end
  end

  defp move_channel(channel_id, destination, request, config, requester) do
    with {:ok, bridges} <- resources("/bridges", config, requester),
         true <- safe_membership?(bridges, request.bindings["external"], request.bindings["app"], request.bindings["consult"]) do
      previous = Enum.filter(bridges, &(channel_id in (&1["channels"] || []) and &1["id"] != destination))
      result = Enum.reduce_while(previous, :ok, fn bridge, :ok ->
        case api(:post, "/bridges/" <> bridge["id"] <> "/removeChannel", %{channel: channel_id}, config, requester, request) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      with :ok <- result,
           {:ok, target} <- api(:get, "/bridges/" <> destination, %{}, config, requester) do
        if channel_id in (target["channels"] || []) do
          :ok
        else
          case api(:post, "/bridges/" <> destination <> "/addChannel", %{channel: channel_id}, config, requester, request) do
            {:ok, _} -> :ok
            error -> error
          end
        end
      end
    else
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp resources(path, config, requester) do
    with {:ok, values} when is_list(values) <- api(:get, path, %{}, config, requester),
         true <- length(values) <= @max_resources,
         true <- Enum.all?(values, &(is_map(&1) and safe_id?(&1["id"]))),
         true <- length(Enum.uniq_by(values, & &1["id"])) == length(values),
         true <- path != "/bridges" or Enum.all?(values, fn bridge ->
           is_list(bridge["channels"]) and length(bridge["channels"]) <= @max_resources and
             Enum.all?(bridge["channels"], &safe_id?/1) and
             length(Enum.uniq(bridge["channels"])) == length(bridge["channels"])
         end) do
      {:ok, values}
    else
      _ -> {:error, :telephony_pbx_binding_invalid}
    end
  end

  defp api(method, path, parameters, config, requester, effect_request \\ nil) do
    remaining = config.deadline - System.monotonic_time(:millisecond)
    if remaining <= 0 or (method != :get and
         (is_nil(effect_request) or DateTime.compare(effect_request.expires_at, now()) != :gt)) do
      {:error, :telephony_outcome_unknown}
    else
      {variables, query} = Map.pop(parameters, :variables)
      suffix = query |> Enum.map(fn {key, value} -> {Atom.to_string(key), to_string(value)} end) |> URI.encode_query()
      url = config.origin <> "/ari" <> path <> if(suffix == "", do: "", else: "?" <> suffix)
      headers = [{"authorization", "Basic " <> Base.encode64(config.username <> ":" <> config.password)},
        {"accept", "application/json"}, {"content-type", "application/json"}]
      body = if variables, do: Jason.encode!(%{variables: variables}), else: ""
      case requester.(method, url, headers, body, allowed_hosts: [config.host], allowed_ports: [443],
          timeout_ms: min(5_000, remaining), max_response_bytes: @max_body) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          if response in [nil, ""], do: {:ok, %{}}, else: Jason.decode(response)
        {:ok, %{status: 404}} -> {:error, :not_found}
        _ -> {:error, :telephony_outcome_unknown}
      end
    end
  rescue
    _ -> {:error, :telephony_outcome_unknown}
  end

  defp bound?(channel, request, role) do
    vars = if is_map(channel), do: channel["channelvars"], else: nil
    is_map(vars) and vars["KC_TENANT_ID"] == request.tenant_id and vars["KC_CALL_ID"] == request.call_id and
      vars["KC_LIVEKIT_ROOM"] == request.provider_room and vars["KC_SIP_IDENTITY"] == request.provider_identity and
      vars["KC_ROLE"] == role
  end
  defp approved_prompt?(prompt), do: prompt in Application.get_env(:comms_integrations, :telephony_ivr_prompt_allowlist, [])
  defp valid_allowlist? do
    prompts = Application.get_env(:comms_integrations, :telephony_ivr_prompt_allowlist, [])
    is_list(prompts) and length(prompts) in 1..20 and length(Enum.uniq(prompts)) == length(prompts) and
      Enum.all?(prompts, &(is_binary(&1) and Regex.match?(~r/^sound:[A-Za-z0-9_\/-]{1,150}$/, &1)))
  end
  defp playback_identity(value) when is_binary(value) do
    case Regex.run(~r/^kc_ivr_([0-9a-f]{32})_([1-3])$/, value) do
      [_, id, step] ->
        <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> = id
        {:ok, Enum.join([a, b, c, d, e], "-"), String.to_integer(step)}
      _ -> {:error, :invalid_provider_event}
    end
  end
  defp playback_identity(_), do: {:error, :invalid_provider_event}
  defp step(value) when value in ["1", "2", "3"], do: {:ok, String.to_integer(value)}
  defp step(_), do: {:error, :invalid_provider_event}
  defp receipt_id?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp safe_id?(value), do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_.:-]{1,200}$/, value)
  defp valid_text?(value), do: is_binary(value) and byte_size(value) in 1..200 and String.trim(value) != ""
  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp compact(value), do: String.replace(value, "-", "")
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp secure_equal?(left, right), do: :crypto.hash_equals(left, right)
end
