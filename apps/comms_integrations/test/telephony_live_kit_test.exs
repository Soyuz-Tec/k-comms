defmodule CommsIntegrations.Telephony.LiveKitTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.Telephony
  alias CommsIntegrations.Telephony.{Config, LiveKit, LiveKitWebhook}

  @secret "synthetic-livekit-secret-minimum-32-bytes"

  setup do
    values = %{
      telephony_provider_mode: "livekit",
      audio_provider_mode: "livekit",
      livekit_server_url: "wss://media.example.test",
      livekit_api_url: "https://media.example.test",
      livekit_api_key: "synthetic-api-key",
      livekit_api_secret: @secret,
      telephony_ring_timeout_seconds: 45,
      telephony_max_duration_seconds: 1_800,
      allow_insecure_local_media: false,
      telephony_transfer_enabled: false,
      telephony_transfer_destination_prefixes: []
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

  test "disabled facade does not advertise usable telephony or initiate provider calls" do
    Application.put_env(:comms_integrations, :telephony_provider_mode, "disabled")
    refute Telephony.enabled?()
    refute Telephony.ready?()
    assert Telephony.status() == %{enabled: false, configured: false, provider: "disabled"}
    assert Telephony.create_outbound(command()) == {:error, :telephony_provider_unavailable}
    assert LiveKitWebhook.verify("{}", "token") == {:error, :invalid_provider_webhook}
  end

  test "SIP request waits for remote answer with a narrow server-only grant and bounded duration" do
    parent = self()

    requester = fn method, url, headers, body, options ->
      send(parent, {:request, method, url, headers, Jason.decode!(body), options})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             sipCallId: "SC_provider",
             roomName: "kc_phone_room",
             participantIdentity: "sip_exact"
           })
       }}
    end

    assert {:ok, %{provider_call_id: "SC_provider", state: :answered}} =
             LiveKit.create_outbound(command(), requester)

    assert_receive {:request, :post,
                    "https://media.example.test/twirp/livekit.SIP/CreateSIPParticipant", headers,
                    body, options}

    assert body["wait_until_answered"] == true
    assert body["ringing_timeout"] == "45s"
    assert body["max_call_duration"] == "1800s"
    assert body["room_name"] == "kc_phone_room"
    assert body["participant_identity"] == "sip_exact"
    assert body["sip_trunk_id"] == "ST_outbound"
    assert body["sip_call_to"] == "+15550001002"
    assert body["sip_number"] == "+15550001001"
    assert options[:timeout_ms] == 60_000
    assert options[:allowed_hosts] == ["media.example.test"]
    {"authorization", "Bearer " <> token} = List.keyfind(headers, "authorization", 0)
    [_header, payload, _signature] = String.split(token, ".")
    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["sip"] == %{"call" => true}
    refute Map.has_key?(claims, "video")
    refute Map.has_key?(claims, "sub")
  end

  test "native blind transfer uses actual REFER RPC and exact SIP identity with bounded acknowledgement" do
    Application.put_env(:comms_integrations, :telephony_transfer_enabled, true)
    Application.put_env(:comms_integrations, :telephony_transfer_destination_prefixes, ["+1555"])

    control = %{
      action: :blind_transfer,
      provider_room: "kc_phone_room",
      provider_identity: "sip_exact",
      destination: "+15550001003"
    }

    requester = fn :post, url, headers, body, options ->
      assert url == "https://media.example.test/twirp/livekit.SIP/TransferSIPParticipant"
      decoded = Jason.decode!(body)
      assert decoded["room_name"] == control.provider_room
      assert decoded["participant_identity"] == control.provider_identity
      assert decoded["transfer_to"] == "tel:+15550001003"
      assert decoded["ringing_timeout"] == "45s"
      assert options[:timeout_ms] == 10_000
      assert options[:allowed_hosts] == ["media.example.test"]
      {"authorization", "Bearer " <> token} = List.keyfind(headers, "authorization", 0)
      [_header, payload, _signature] = String.split(token, ".")
      claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert claims["sip"] == %{"call" => true}
      refute Map.has_key?(claims, "video")
      {:ok, %{status: 200, body: "{}"}}
    end

    assert {:ok, :submitted} = LiveKit.execute_control(control, requester)
    forbidden = fn _, _, _, _, _ -> flunk("unqualified transfer reached transport") end

    assert {:error, :telephony_destination_forbidden} =
             LiveKit.execute_control(%{control | destination: "+442071234567"}, forbidden)

    Application.put_env(:comms_integrations, :telephony_transfer_enabled, false)
    assert {:error, :telephony_control_unsupported} = LiveKit.execute_control(control, forbidden)
  end

  test "uncertain native REFER acknowledgement is returned without retransmission or false unsupported claim" do
    Application.put_env(:comms_integrations, :telephony_transfer_enabled, true)
    Application.put_env(:comms_integrations, :telephony_transfer_destination_prefixes, ["+1555"])

    control = %{
      action: :blind_transfer,
      provider_room: "kc_phone_room",
      provider_identity: "sip_exact",
      destination: "+15550001003"
    }

    requester = fn _, _, _, _, _ ->
      send(self(), :refer_attempt)
      {:ok, %{status: 503, body: "synthetic uncertain response"}}
    end

    assert {:error, :telephony_outcome_unknown} = LiveKit.execute_control(control, requester)
    assert_received :refer_attempt
    refute_received :refer_attempt
  end

  test "unsafe destinations never reach the transport" do
    requester = fn _, _, _, _, _ -> flunk("invalid command contacted the provider") end

    assert LiveKit.create_outbound(
             %{command() | to_number: "sip:attacker@example.test"},
             requester
           ) == {:error, :invalid_telephony_command}

    assert LiveKit.create_outbound(
             %{command() | from_number: "+15550001001\r\nInjected: header"},
             requester
           ) == {:error, :invalid_telephony_command}
  end

  test "ambiguous network failure stays uncertain and never retries dialing" do
    parent = self()

    requester = fn _, _, _, _, _ ->
      send(parent, :dial_attempt)
      {:error, :outbound_timeout}
    end

    assert LiveKit.create_outbound(command(), requester) == {:error, :telephony_outcome_unknown}
    assert_receive :dial_attempt
    refute_receive :dial_attempt

    assert LiveKit.create_outbound(command(), fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: "{}"}}
           end) == {:error, :telephony_outcome_unknown}

    assert LiveKit.create_outbound(command(), fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: "[]"}}
           end) == {:error, :telephony_outcome_unknown}
  end

  test "provider SIP outcomes remain distinct without leaking provider response content" do
    Enum.each(
      [{"486", :busy}, {"480", :no_answer}, {"408", :no_answer}, {"603", :declined}],
      fn {code, outcome} ->
        response = %{
          status: 408,
          body:
            Jason.encode!(%{
              code: "deadline_exceeded",
              msg: "private carrier diagnostic",
              meta: %{sip_status_code: code}
            })
        }

        assert LiveKit.create_outbound(command(), fn _, _, _, _, _ -> {:ok, response} end) ==
                 {:error, outcome}
      end
    )
  end

  test "reconciliation reads authoritative SIP state and verifies the requested identity" do
    requester = fn _, url, _, body, _ ->
      assert url =~ "/twirp/livekit.RoomService/GetParticipant"
      assert Jason.decode!(body) == %{"room" => "kc_phone_room", "identity" => "sip_exact"}

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             identity: "sip_exact",
             attributes: %{"sip.callID" => "SC_provider", "sip.callStatus" => "active"}
           })
       }}
    end

    assert {:ok, %{state: :answered, provider_call_id: "SC_provider"}} =
             LiveKit.get_participant("kc_phone_room", "sip_exact", requester)

    assert LiveKit.get_participant("kc_phone_room", "sip_exact", fn _, _, _, _, _ ->
             {:ok, %{status: 404, body: "{\"code\":\"not_found\"}"}}
           end) == {:error, :not_found}

    assert LiveKit.get_participant("kc_phone_room", "sip_exact", fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: Jason.encode!(%{identity: "other", attributes: %{}})}}
           end) == {:error, :telephony_provider_unavailable}
  end

  test "cleanup deletes the isolated room and treats a missing room as already ended" do
    requester = fn _, url, _, body, _ ->
      assert url =~ "/twirp/livekit.RoomService/DeleteRoom"
      assert Jason.decode!(body) == %{"room" => "kc_phone_room"}
      {:ok, %{status: 404, body: "{\"code\":\"not_found\"}"}}
    end

    assert LiveKit.end_call("kc_phone_room", requester) == :ok

    assert LiveKit.end_call("kc_phone_room", fn _, _, _, _, _ -> {:error, :outbound_timeout} end) ==
             {:error, :telephony_provider_unavailable}

    assert LiveKit.end_call("kc_phone_room", fn _, _, _, _, _ ->
             {:ok, %{status: 404, body: ""}}
           end) == {:error, :telephony_provider_unavailable}
  end

  test "cleanup bounds the entire transport lifecycle and rejects a late acknowledgement" do
    parent = self()

    requester = fn _, _, _, _, options ->
      send(parent, {:cleanup_transport_started, self(), options[:timeout_ms]})

      receive do
        :complete -> {:ok, %{status: 200, body: "{}"}}
      end
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, :telephony_provider_unavailable} =
             LiveKit.end_call("kc_phone_room", requester, 25)

    assert_receive {:cleanup_transport_started, pid, 25}
    refute Process.alive?(pid)
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "actual loopback cleanup transport cannot wait beyond its complete request deadline" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        case :gen_tcp.accept(listener) do
          {:ok, socket} ->
            send(parent, :cleanup_socket_accepted)

            receive do
              :stop -> :gen_tcp.close(socket)
            end

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    Application.put_env(:comms_integrations, :allow_insecure_local_media, true)
    Application.put_env(:comms_integrations, :livekit_api_url, "http://127.0.0.1:#{port}")
    Application.put_env(:comms_integrations, :livekit_server_url, "ws://127.0.0.1:#{port}")
    started = System.monotonic_time(:millisecond)

    assert {:error, :telephony_provider_unavailable} =
             LiveKit.end_call("kc_phone_room")

    assert_receive :cleanup_socket_accepted
    assert System.monotonic_time(:millisecond) - started < 7_000
    send(server, :stop)
  end

  test "disabling new telephony calls retains reconciliation and cleanup for existing legs" do
    Application.put_env(:comms_integrations, :telephony_provider_mode, "disabled")
    refute Telephony.ready?()
    assert Telephony.create_outbound(command()) == {:error, :telephony_provider_unavailable}

    assert LiveKit.end_call("kc_phone_room", fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: "{}"}}
           end) == :ok

    assert {:ok, %{state: :answered}} =
             LiveKit.get_participant("kc_phone_room", "sip_exact", fn _, _, _, _, _ ->
               {:ok,
                %{
                  status: 200,
                  body:
                    Jason.encode!(%{
                      identity: "sip_exact",
                      attributes: %{"sip.callID" => "SC_provider", "sip.callStatus" => "active"}
                    })
                }}
             end)
  end

  test "disabled admissions still authenticate existing call endings without enabling new calls" do
    Application.put_env(:comms_integrations, :telephony_provider_mode, "disabled")
    event = %{inbound_event() | "event" => "participant_left"}
    body = Jason.encode!(event)
    assert {:ok, ^event} = LiveKitWebhook.verify(body, webhook_token(body))

    assert {:ok,
            %{
              event_type: "participant_left",
              participant_sid: "PA_sip_exact",
              admission_enabled: false
            }} = LiveKit.verify_webhook(body, webhook_token(body))

    assert LiveKit.verify_webhook(body <> " ", webhook_token(body)) ==
             {:error, :invalid_provider_webhook}

    refute Telephony.enabled?()
    assert Telephony.create_outbound(command()) == {:error, :telephony_provider_unavailable}
  end

  test "webhook signature binds the exact raw body, expected issuer, and required expiry" do
    body = Jason.encode!(inbound_event())
    token = webhook_token(body)
    assert {:ok, event} = LiveKitWebhook.verify(body, token)
    assert {:ok, _} = LiveKitWebhook.verify(body, "Bearer " <> token)

    assert {:ok,
            %{
              from_number: "+15550001002",
              to_number: "+15550001001",
              trunk_id: "ST_inbound",
              sip_status: "ringing",
              occurred_at: %DateTime{}
            }} = LiveKit.normalize_webhook(event)

    assert LiveKitWebhook.verify(body <> " ", token) == {:error, :invalid_provider_webhook}

    assert LiveKitWebhook.verify(body, webhook_token(body, %{"iss" => "other-project"})) ==
             {:error, :invalid_provider_webhook}

    assert LiveKitWebhook.verify(
             body,
             webhook_token(body, %{"exp" => System.system_time(:second) - 1})
           ) == {:error, :invalid_provider_webhook}

    assert LiveKitWebhook.verify(body, webhook_token(body, %{"exp" => nil})) ==
             {:error, :invalid_provider_webhook}

    # Ordinary browser room credentials have no body digest and cannot be
    # replayed as provider callbacks, even though the project issuer matches.
    assert LiveKitWebhook.verify(body, webhook_token(body, %{"sha256" => nil})) ==
             {:error, :invalid_provider_webhook}

    assert LiveKitWebhook.verify(
             body,
             webhook_token(body, %{"nbf" => System.system_time(:second) + 120})
           ) == {:error, :invalid_provider_webhook}

    assert LiveKitWebhook.verify(body, webhook_token(body, %{}, "wrong-secret")) ==
             {:error, :invalid_provider_webhook}

    assert LiveKitWebhook.verify(String.duplicate("x", 262_145), token) ==
             {:error, :invalid_provider_webhook}
  end

  test "unrelated signed events can be acknowledged while malformed events fail closed" do
    assert LiveKit.normalize_webhook(%{"event" => "track_published"}) ==
             {:error, :unsupported_provider_event}

    assert LiveKit.normalize_webhook(%{inbound_event() | "participant" => []}) ==
             {:error, :invalid_provider_event}

    assert LiveKit.normalize_webhook(%{inbound_event() | "createdAt" => "invalid"}) ==
             {:error, :invalid_provider_event}

    without_sid = Map.update!(inbound_event(), "participant", &Map.delete(&1, "sid"))
    assert LiveKit.normalize_webhook(without_sid) == {:error, :invalid_provider_event}

    oversized_sid =
      Map.update!(inbound_event(), "participant", &Map.put(&1, "sid", String.duplicate("x", 201)))

    assert LiveKit.normalize_webhook(oversized_sid) == {:error, :invalid_provider_event}
  end

  test "provider webhook port implementation verifies before normalizing and binds its own adapter" do
    body = Jason.encode!(inbound_event())

    assert {:ok,
            %{participant_kind: :sip, provider_call_id: "SC_provider", admission_enabled: true}} =
             LiveKit.verify_webhook(body, webhook_token(body))

    assert LiveKit.verify_webhook(body <> " ", webhook_token(body)) ==
             {:error, :invalid_provider_webhook}

    assert LiveKit.authorized_adapter?(LiveKit)
    refute LiveKit.authorized_adapter?(__MODULE__)
  end

  test "configuration readiness fails closed rather than accepting production placeholders" do
    assert Telephony.ready?()

    Application.put_env(
      :comms_integrations,
      :livekit_api_secret,
      "CHANGE_ME_secret_which_is_long_enough"
    )

    refute Telephony.ready?()
    assert {:error, :livekit_api_secret} = Config.configuration()
  end

  defp command do
    %{
      call_id: "call-id",
      provider_room: "kc_phone_room",
      provider_identity: "sip_exact",
      outbound_trunk_id: "ST_outbound",
      from_number: "+15550001001",
      to_number: "+15550001002"
    }
  end

  defp inbound_event do
    %{
      "event" => "participant_joined",
      "id" => "event-1",
      "createdAt" => "1720000000",
      "room" => %{"name" => "kc_phone_room"},
      "participant" => %{
        "identity" => "sip_exact",
        "sid" => "PA_sip_exact",
        "kind" => "SIP",
        "attributes" => %{
          "sip.callID" => "SC_provider",
          "sip.trunkID" => "ST_inbound",
          "sip.phoneNumber" => "+15550001002",
          "sip.trunkPhoneNumber" => "+15550001001",
          "sip.callStatus" => "ringing"
        }
      }
    }
  end

  defp webhook_token(body, overrides \\ %{}, secret \\ @secret) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "synthetic-api-key",
          "exp" => now + 60,
          "nbf" => now - 5,
          "sha256" => Base.encode64(:crypto.hash(:sha256, body))
        },
        overrides
      )

    header = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    input = header <> "." <> payload
    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, input), padding: false)
  end
end
