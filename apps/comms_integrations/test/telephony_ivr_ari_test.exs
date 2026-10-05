defmodule CommsIntegrations.Telephony.IvrARITest do
  use ExUnit.Case, async: false
  alias CommsCore.Telephony.IvrProviderRequest
  alias CommsIntegrations.Telephony.IvrARI
  @call "4acf5490-60ba-439d-8a74-84960a9a1e4d"
  @tenant "8c1a31c4-665a-44e3-bdfa-e2d0d4c45c29"
  @run "92df0e80-041f-4888-8b85-6d5eae265aff"
  @secret String.duplicate("s", 32)

  setup do
    values = %{
      telephony_pbx_enabled: true,
      telephony_pbx_qualified: true,
      telephony_ivr_qualified: true,
      telephony_pbx_api_url: "https://pbx.example.test",
      telephony_pbx_username: "k-comms",
      telephony_pbx_password: "synthetic-provider-secret-long-enough",
      telephony_pbx_endpoint: "carrier",
      telephony_pbx_application: "k-comms",
      telephony_pbx_destination_prefixes: ["+1415"],
      telephony_pbx_webhook_secret: @secret,
      telephony_ivr_prompt_allowlist: ["sound:custom/menu"]
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_integrations, key, value)
        {key, :error} -> Application.delete_env(:comms_integrations, key)
      end)
    end)

    :ok
  end

  test "qualification and authenticated event relay are both required" do
    assert IvrARI.ready?()
    Application.put_env(:comms_integrations, :telephony_ivr_qualified, false)
    refute IvrARI.ready?()
    Application.put_env(:comms_integrations, :telephony_ivr_qualified, true)
    Application.delete_env(:comms_integrations, :telephony_pbx_webhook_secret)
    refute IvrARI.ready?()
  end

  test "forward playback freezes caller bindings and keeps the exact app leg outside prompt audio" do
    {state, requester} = protocol()
    request = application_request()
    assert {:ok, :pending} = IvrARI.play(%{request | reconcile: false}, requester)
    snapshot = Agent.get(state, & &1)
    assert snapshot.bridges[request.bindings["holding"]]["channels"] == ["external"]
    assert snapshot.bridges["original"]["channels"] == ["app"]
    assert snapshot.channels["external"]["channelvars"]["KC_IVR_RUN_ID"] == @run
    assert snapshot.channels["external"]["channelvars"]["KC_IVR_STEP"] == "1"

    seconds =
      snapshot.channels["external"]["channelvars"]["TIMEOUT(absolute)"] |> String.to_integer()

    assert seconds in 1..45
    assert snapshot.playbacks[request.playback_id]["target_uri"] == "channel:external"
    assert snapshot.playbacks[request.playback_id]["media_uri"] == "sound:custom/menu"
    assert {:ok, :pending} = IvrARI.play(request, requester)
    requests = Agent.get(state, & &1.requests)

    assert Enum.count(requests, fn {method, path, _} ->
             method == :post and String.contains?(path, "/play/")
           end) == 1
  end

  test "destination origination is observed by exact deterministic role and connection needs a two-leg bridge" do
    {state, requester} = protocol()
    request = %{application_request() | destination: "+14155550123", reconcile: false}
    assert {:ok, :pending} = IvrARI.destination(request, requester)
    consult = request.bindings["consult"]
    snapshot = Agent.get(state, & &1)
    assert snapshot.channels[consult]["channelvars"]["KC_ROLE"] == "consult"
    assert snapshot.channels[consult]["channelvars"]["KC_CALL_ID"] == @call
    assert {:ok, :pending} = IvrARI.destination(%{request | reconcile: true}, requester)
    Agent.update(state, &put_in(&1, [:channels, consult, "state"], "Up"))
    assert {:ok, :ready} = IvrARI.destination(%{request | reconcile: true}, requester)
    assert {:ok, :connected} = IvrARI.destination(%{request | stage: :connect}, requester)
    snapshot = Agent.get(state, & &1)

    assert Enum.sort(snapshot.bridges[request.bindings["destination_bridge"]]["channels"]) ==
             Enum.sort(["external", consult])

    assert snapshot.bridges["original"]["channels"] == ["app"]

    assert Enum.count(snapshot.requests, fn {method, path, _} ->
             method == :post and path == "/ari/channels"
           end) == 1

    assert {:ok, :connected} =
             IvrARI.destination(%{request | stage: :connect, reconcile: true}, requester)

    assert Agent.get(state, & &1.requests)
           |> Enum.count(fn {method, path, _} -> method == :post and path == "/ari/channels" end) ==
             1
  end

  test "a done playback read has no timestamp and cannot open the caller digit window" do
    request = request()

    requester =
      transport(fn path ->
        case path do
          "/ari/channels" ->
            [channel()]

          "/ari/bridges" ->
            []

          _ ->
            %{
              id: request.playback_id,
              state: "done",
              target_uri: "channel:external",
              media_uri: request.prompt_media
            }
        end
      end)

    assert {:ok, :pending} = IvrARI.play(request, requester)
    assert_receive {:request, :get, "/ari/playbacks/" <> _}
    refute_receive {:request, :post, _}
  end

  test "uncertain missing outbound leg is observed read-only and never redialed" do
    requester =
      transport(fn path ->
        case path do
          "/ari/channels" -> [channel()]
          "/ari/bridges" -> []
          _ -> :missing
        end
      end)

    assert {:error, :telephony_outcome_unknown} =
             IvrARI.destination(%{request() | destination: "+14155550123"}, requester)

    refute_receive {:request, :post, _}
  end

  test "foreign caller binding rejects playback before any forward mutation" do
    requester =
      transport(fn _ ->
        [%{channel() | channelvars: Map.put(channel().channelvars, "KC_TENANT_ID", "foreign")}]
      end)

    assert {:error, :telephony_pbx_binding_invalid} =
             IvrARI.play(%{request() | reconcile: false}, requester)

    refute_receive {:request, :post, _}
  end

  test "expired authority cannot reach a transport" do
    requester = fn _, _, _, _, _ -> flunk("expired request reached provider") end

    assert {:error, :telephony_ivr_unavailable} =
             IvrARI.play(
               %{request() | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)},
               requester
             )
  end

  test "signed caller events preserve original time, reject application role and wrong-body signatures" do
    event = %{
      type: "ChannelDestroyed",
      event_id: String.duplicate("a", 64),
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      channel: %{
        channel()
        | channelvars:
            Map.merge(channel().channelvars, %{"KC_IVR_RUN_ID" => @run, "KC_IVR_STEP" => "1"})
      }
    }

    body = Jason.encode!(event)
    auth = signed(body)
    assert {:ok, %{type: :disconnected, digit: nil}} = IvrARI.verify_event(body, auth)
    assert {:error, :invalid_provider_webhook} = IvrARI.verify_event(body <> " ", auth)
    application = put_in(event, [:channel, :channelvars, "KC_ROLE"], "app")

    assert {:error, :invalid_provider_webhook} =
             IvrARI.verify_event(Jason.encode!(application), signed(Jason.encode!(application)))
  end

  defp request do
    compact = String.replace(@call, "-", "")

    %IvrProviderRequest{
      run_id: @run,
      call_id: @call,
      tenant_id: @tenant,
      provider_room: "room",
      provider_identity: "sip",
      step: 1,
      playback_id: "kc_ivr_" <> String.replace(@run, "-", "") <> "_1",
      prompt_media: "sound:custom/menu",
      bindings: %{
        "external" => "external",
        "app" => nil,
        "mixing" => "original",
        "holding" => "kc_hold_" <> compact,
        "consult" => "kc_consult_" <> compact,
        "recording" => "kc_vm_" <> compact,
        "destination_bridge" => "kc_ivr_mix_" <> compact
      },
      expires_at: DateTime.add(DateTime.utc_now(), 45, :second),
      effect_deadline_ms: System.monotonic_time(:millisecond) + 10_000,
      reconcile: true
    }
  end

  defp application_request do
    request = request()
    %{request | bindings: Map.put(request.bindings, "app", "app")}
  end

  # Local protocol fixture only; no provider call, carrier qualification or
  # audible-media assertion is made by these transport tests.
  defp protocol do
    external = channel() |> Jason.encode!() |> Jason.decode!()
    app = external |> Map.put("id", "app") |> put_in(["channelvars", "KC_ROLE"], "app")

    {:ok, state} =
      start_supervised(
        {Agent,
         fn ->
           %{
             channels: %{"external" => external, "app" => app},
             bridges: %{
               "original" => %{
                 "id" => "original",
                 "bridge_type" => "mixing",
                 "channels" => ["external", "app"]
               }
             },
             playbacks: %{},
             requests: []
           }
         end}
      )

    requester = fn method, url, _headers, body, _options ->
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")
      path = uri.path

      Agent.get_and_update(state, fn snapshot ->
        snapshot = %{snapshot | requests: snapshot.requests ++ [{method, path, query}]}

        cond do
          method == :get and path == "/ari/channels" ->
            {ok(Map.values(snapshot.channels)), snapshot}

          method == :get and path == "/ari/bridges" ->
            {ok(Map.values(snapshot.bridges)), snapshot}

          method == :get and String.starts_with?(path, "/ari/channels/") ->
            {found(snapshot.channels[String.replace_prefix(path, "/ari/channels/", "")]),
             snapshot}

          method == :get and String.starts_with?(path, "/ari/bridges/") ->
            {found(snapshot.bridges[String.replace_prefix(path, "/ari/bridges/", "")]), snapshot}

          method == :get and String.starts_with?(path, "/ari/playbacks/") ->
            {found(snapshot.playbacks[String.replace_prefix(path, "/ari/playbacks/", "")]),
             snapshot}

          method == :post and String.ends_with?(path, "/variable") ->
            id =
              path
              |> String.replace_prefix("/ari/channels/", "")
              |> String.replace_suffix("/variable", "")

            {ok(%{}),
             put_in(snapshot, [:channels, id, "channelvars", query["variable"]], query["value"])}

          method == :post and String.contains?(path, "/play/") ->
            [id, playback_id] =
              path |> String.replace_prefix("/ari/channels/", "") |> String.split("/play/")

            playback = %{
              "id" => playback_id,
              "state" => "playing",
              "target_uri" => "channel:" <> id,
              "media_uri" => query["media"]
            }

            {ok(playback), put_in(snapshot, [:playbacks, playback_id], playback)}

          method == :post and path == "/ari/channels" ->
            id = query["channelId"]

            created = %{
              "id" => id,
              "state" => "Down",
              "channelvars" => Jason.decode!(body)["variables"]
            }

            {ok(created), put_in(snapshot, [:channels, id], created)}

          method == :post and String.ends_with?(path, "/removeChannel") ->
            id =
              path
              |> String.replace_prefix("/ari/bridges/", "")
              |> String.replace_suffix("/removeChannel", "")

            {ok(%{}),
             update_in(snapshot, [:bridges, id, "channels"], &List.delete(&1, query["channel"]))}

          method == :post and String.ends_with?(path, "/addChannel") ->
            id =
              path
              |> String.replace_prefix("/ari/bridges/", "")
              |> String.replace_suffix("/addChannel", "")

            {ok(%{}),
             update_in(snapshot, [:bridges, id, "channels"], &Enum.uniq([query["channel"] | &1]))}

          method == :post and String.starts_with?(path, "/ari/bridges/") ->
            id = String.replace_prefix(path, "/ari/bridges/", "")
            created = %{"id" => id, "bridge_type" => query["type"], "channels" => []}
            {ok(created), put_in(snapshot, [:bridges, id], created)}

          String.ends_with?(path, "/moh") ->
            {ok(%{}), snapshot}

          true ->
            {found(nil), snapshot}
        end
      end)
    end

    {state, requester}
  end

  defp ok(value), do: {:ok, %{status: 200, body: Jason.encode!(value)}}
  defp found(nil), do: {:ok, %{status: 404, body: ""}}
  defp found(value), do: ok(value)

  defp channel,
    do: %{
      id: "external",
      state: "Up",
      channelvars: %{
        "KC_TENANT_ID" => @tenant,
        "KC_CALL_ID" => @call,
        "KC_LIVEKIT_ROOM" => "room",
        "KC_SIP_IDENTITY" => "sip",
        "KC_ROLE" => "external"
      }
    }

  defp transport(response),
    do: fn method, url, _headers, _body, _options ->
      path = URI.parse(url).path
      send(self(), {:request, method, path})

      case response.(path) do
        :missing -> {:ok, %{status: 404, body: ""}}
        value -> {:ok, %{status: 200, body: Jason.encode!(value)}}
      end
    end

  defp signed(body) do
    timestamp = Integer.to_string(System.system_time(:second))

    digest =
      :crypto.mac(:hmac, :sha256, @secret, timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    "v1:" <> timestamp <> ":" <> digest
  end
end
