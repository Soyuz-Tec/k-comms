defmodule CommsWeb.TelephonyControllerTest do
  use CommsWeb.ConnCase, async: false

  @moduletag :integration
  @moduletag :call

  alias CommsCore.{Repo, Telephony}
  alias CommsCore.Accounts.User
  alias CommsCore.Telephony.Call
  alias CommsTestSupport.Fixtures

  setup do
    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    values = %{
      telephony_provider_mode: "disabled",
      audio_provider_mode: "livekit",
      livekit_server_url: "wss://media.example.test",
      livekit_api_url: "https://media.example.test",
      livekit_api_key: "test-telephony-key",
      livekit_api_secret: "test-telephony-secret-at-least-32-bytes"
    }

    previous =
      Map.new(values, fn {key, _value} -> {key, Application.get_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    previous_callback = Application.get_env(:comms_core, :telephony_callback_adapter)

    Application.put_env(
      :comms_core,
      :telephony_callback_adapter,
      CommsIntegrations.Telephony.LiveKit
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_integrations, key),
          else: Application.put_env(:comms_integrations, key, value)
      end)

      if is_nil(previous_callback),
        do: Application.delete_env(:comms_core, :telephony_callback_adapter),
        else: Application.put_env(:comms_core, :telephony_callback_adapter, previous_callback)
    end)

    {:ok, account: account, token: token}
  end

  test "telephone APIs require a current authenticated human session" do
    assert build_conn() |> get("/api/v1/telephony/config") |> json_response(401)
    assert build_conn() |> get("/api/v1/telephony/calls") |> json_response(401)

    assert build_conn()
           |> post("/api/v1/telephony/calls", %{destination: "+15550001002"})
           |> json_response(401)
  end

  test "disabled provider is visible and cannot create a durable outbound call", %{token: token} do
    config =
      authenticated(token)
      |> get("/api/v1/telephony/config")
      |> json_response(200)
      |> schema_fixture("config-disabled")

    assert config["data"]["enabled"] == false
    assert config["data"]["configured"] == false
    assert config["data"]["provider_ready"] == false
    assert config["data"]["line_assigned"] == false
    assert config["data"]["provider"] == "livekit_sip"
    assert config["data"]["number"] == nil

    response =
      authenticated(token)
      |> post("/api/v1/telephony/calls", %{
        destination: "+15550001002",
        idempotency_key: Ecto.UUID.generate()
      })
      |> json_response(503)

    assert response["error"]["code"] == "telephony_disabled"
    assert Repo.aggregate(Call, :count) == 0
  end

  test "configuration distinguishes missing provider setup from an unassigned personal line", %{
    account: account,
    token: token
  } do
    Application.put_env(:comms_integrations, :telephony_provider_mode, "livekit")

    unassigned = authenticated(token) |> get("/api/v1/telephony/config") |> json_response(200)
    assert unassigned["data"]["enabled"]
    assert unassigned["data"]["provider_ready"]
    refute unassigned["data"]["line_assigned"]
    refute unassigned["data"]["configured"]

    Fixtures.step_up(account)
    assert {:ok, _} = Telephony.provision(number_attrs(account), Fixtures.subject(account))
    Application.put_env(:comms_integrations, :livekit_api_secret, nil)

    provider_missing =
      authenticated(token) |> get("/api/v1/telephony/config") |> json_response(200)

    assert provider_missing["data"]["enabled"]
    refute provider_missing["data"]["provider_ready"]
    assert provider_missing["data"]["line_assigned"]
    refute provider_missing["data"]["configured"]

    admin = authenticated(token) |> get("/api/v1/admin/telephony") |> json_response(200)
    assert admin["data"]["line_assigned"]
    refute admin["data"]["provider_ready"]
    assert Repo.aggregate(Call, :count) == 0
  end

  test "personal history remains readable after line reassignment and service disabling", %{
    account: account,
    token: token
  } do
    provision(account)

    started =
      authenticated(token)
      |> post("/api/v1/telephony/calls", %{
        destination: "+15550001002",
        idempotency_key: Ecto.UUID.generate()
      })
      |> json_response(201)

    id = started["data"]["id"]

    assert authenticated(token)
           |> post("/api/v1/telephony/calls/#{id}/end", %{})
           |> json_response(200)

    %{user: other_user} = Fixtures.user_fixture(account)
    attrs = Map.put(number_attrs(account), :user_id, other_user.id)
    assert {:ok, _} = Telephony.provision(attrs, Fixtures.subject(account))

    personal_config =
      authenticated(token) |> get("/api/v1/telephony/config") |> json_response(200)

    assert personal_config["data"]["provider_ready"]
    refute personal_config["data"]["line_assigned"]
    assert personal_config["data"]["number"] == nil

    assigned_elsewhere =
      authenticated(token) |> get("/api/v1/telephony/calls") |> json_response(200)

    assert [%{"id" => ^id, "status" => "cancelled"}] = assigned_elsewhere["data"]

    Application.put_env(:comms_integrations, :telephony_provider_mode, "disabled")

    disabled_history =
      authenticated(token) |> get("/api/v1/telephony/calls") |> json_response(200)

    assert disabled_history["data"] == assigned_elsewhere["data"]
    assert Repo.aggregate(Call, :count) == 1
  end

  test "provisioning requires recent step-up and exposes no provider credentials", %{
    account: account,
    token: token
  } do
    attrs = number_attrs(account)

    assert authenticated(token)
           |> put("/api/v1/admin/telephony", attrs)
           |> json_response(428)
           |> get_in(["error", "code"]) == "step_up_required"

    Fixtures.step_up(account)

    response =
      authenticated(token)
      |> put("/api/v1/admin/telephony", attrs)
      |> json_response(200)
      |> schema_fixture("provision")

    assert response["data"]["number"]["phone_number"] == attrs.phone_number
    assert response["data"]["number"]["extension"] == attrs.extension
    assert response["data"]["number"]["inbound_trunk_id"] == attrs.inbound_trunk_id
    refute Map.has_key?(response["data"], "api_secret")
    refute Map.has_key?(response["data"], "provider_room")

    authenticated(token)
    |> get("/api/v1/admin/telephony")
    |> json_response(200)
    |> schema_fixture("admin-config")
  end

  test "ordinary assigned users see their line without tenant trunk administration", %{
    account: account,
    token: token
  } do
    Fixtures.step_up(account)
    assert {:ok, _} = Telephony.provision(number_attrs(account), Fixtures.subject(account))
    assert {:ok, _user} = account.user |> User.changeset(%{role: :member}) |> Repo.update()

    response =
      authenticated(token)
      |> get("/api/v1/telephony/config")
      |> json_response(200)
      |> schema_fixture("config-member")

    assert response["data"]["number"]["phone_number"] == "+15550001001"
    assert response["data"]["can_manage"] == false
    refute Map.has_key?(response["data"]["number"], "inbound_trunk_id")
    refute Map.has_key?(response["data"]["number"], "outbound_trunk_id")

    assert authenticated(token) |> get("/api/v1/admin/telephony") |> json_response(403)

    assert authenticated(token)
           |> put("/api/v1/admin/telephony", number_attrs(account))
           |> json_response(403)
  end

  test "unsigned provider requests cannot create incoming calls" do
    response =
      build_conn()
      |> put_req_header("content-type", "application/webhook+json")
      |> post("/api/v1/telephony/livekit/webhook", "{\"event\":\"participant_joined\"}")
      |> json_response(401)

    assert response["error"]["code"] == "invalid_provider_webhook"
    assert Repo.aggregate(Call, :count) == 0
  end

  test "oversized webhooks are rejected before parsing or signature verification" do
    body = Jason.encode!(%{padding: String.duplicate("x", 262_144)})

    assert_error_sent(413, fn ->
      build_conn()
      |> put_req_header("content-type", "application/webhook+json")
      |> post("/api/v1/telephony/livekit/webhook", body)
    end)

    assert Repo.aggregate(Call, :count) == 0
  end

  test "signed inbound callbacks preserve ringing until SIP connection and deduplicate", %{
    account: account,
    token: token
  } do
    provision(account)
    event = incoming_event("inbound-http-test")
    body = Jason.encode!(event, pretty: true) <> "\n"
    assert webhook(body) |> json_response(200) == %{"data" => %{"accepted" => true}}
    assert webhook(body) |> json_response(200) == %{"data" => %{"accepted" => true}}
    assert Repo.aggregate(Call, :count) == 1

    active =
      authenticated(token)
      |> get("/api/v1/telephony/calls", %{scope: "active"})
      |> json_response(200)
      |> schema_fixture("list-active")

    assert [call] = active["data"]
    assert call["direction"] == "inbound"
    assert call["status"] == "ringing"
    assert call["can_answer"] == true
    refute Map.has_key?(call, "provider_room")
    refute Map.has_key?(call, "provider_call_id")

    accepted_conn =
      authenticated(token) |> post("/api/v1/telephony/calls/#{call["id"]}/answer", %{})

    accepted = accepted_conn |> json_response(200) |> schema_fixture("answer")
    assert get_resp_header(accepted_conn, "cache-control") == ["no-store"]
    assert accepted["data"]["status"] == "ringing"
    assert accepted["data"]["active_on_this_device"] == true
    assert accepted["data"]["can_answer"] == false
    claims = participant_claims(accepted["credential"]["participant_token"])
    assert claims["video"]["room"] == event["room"]["name"]
    assert claims["video"]["roomJoin"] == true
    assert claims["video"]["roomAdmin"] == false

    app_joined = %{
      "event" => "participant_joined",
      "id" => "app-http-test",
      "createdAt" => Integer.to_string(System.system_time(:second)),
      "room" => event["room"],
      "participant" => %{"identity" => claims["sub"], "sid" => "PA_app_http"}
    }

    assert webhook(Jason.encode!(app_joined)) |> json_response(200)

    still_ringing =
      authenticated(token)
      |> get("/api/v1/telephony/calls/#{call["id"]}")
      |> json_response(200)

    assert still_ringing["data"]["status"] == "ringing"
    assert still_ringing["data"]["answered_at"] == nil

    worker = CommsCore.RuntimePorts.job_worker!(:telephony_dispatch)
    assert {:ok, %{reconcile: true}} = Telephony.claim_dispatch(call["id"], worker)

    assert {:ok, :answered} =
             Telephony.complete_dispatch(
               call["id"],
               {:ok, %{provider_call_id: "provider-inbound-http-test", state: :answered}},
               worker
             )

    answered =
      authenticated(token)
      |> get("/api/v1/telephony/calls/#{call["id"]}")
      |> json_response(200)
      |> schema_fixture("show")

    assert answered["data"]["status"] == "answered"
    assert is_binary(answered["data"]["answered_at"])

    ended =
      authenticated(token)
      |> post("/api/v1/telephony/calls/#{call["id"]}/end", %{})
      |> json_response(200)
      |> schema_fixture("end")

    assert ended["data"]["status"] == "ended"
    assert is_integer(ended["data"]["connected_seconds"])
    assert webhook(body) |> json_response(200)

    final =
      authenticated(token) |> get("/api/v1/telephony/calls/#{call["id"]}") |> json_response(200)

    assert final["data"]["status"] == "ended"

    foreign = Fixtures.account_fixture()

    foreign_token =
      foreign
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    assert authenticated(foreign_token)
           |> get("/api/v1/telephony/calls/#{call["id"]}")
           |> json_response(404)
  end

  test "changed bytes invalidate an otherwise valid signed provider event", %{account: account} do
    provision(account)
    body = Jason.encode!(incoming_event("tamper-http-test"), pretty: true)
    authorization = "Bearer " <> webhook_token(body)

    response =
      build_conn()
      |> put_req_header("authorization", authorization)
      |> put_req_header("content-type", "application/webhook+json")
      |> post("/api/v1/telephony/livekit/webhook", body <> " ")
      |> json_response(401)

    assert response["error"]["code"] == "invalid_provider_webhook"
    assert Repo.aggregate(Call, :count) == 0
  end

  test "unrelated signed media events are acknowledged without opening telephone calls", %{
    account: account
  } do
    provision(account)

    event = %{
      "event" => "track_published",
      "id" => "unrelated-http-test",
      "createdAt" => Integer.to_string(System.system_time(:second)),
      "room" => %{"name" => "conversation-room"}
    }

    assert webhook(Jason.encode!(event)) |> json_response(200) ==
             %{"data" => %{"accepted" => true}}

    participant_event =
      event
      |> Map.put("event", "participant_joined")
      |> Map.put("id", "conversation-participant-http-test")
      |> Map.put("participant", %{
        "identity" => "ordinary-meeting-participant",
        "sid" => "PA_meeting_http"
      })

    assert webhook(Jason.encode!(participant_event)) |> json_response(200) ==
             %{"data" => %{"accepted" => true}}

    assert Repo.aggregate(Call, :count) == 0
  end

  test "trusted HTTPS is required for call admission and provider callbacks", %{token: token} do
    previous = Application.get_env(:comms_web, :secure_transport_required)
    Application.put_env(:comms_web, :secure_transport_required, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:comms_web, :secure_transport_required),
        else: Application.put_env(:comms_web, :secure_transport_required, previous)
    end)

    assert authenticated(token)
           |> post("/api/v1/telephony/calls", %{})
           |> json_response(426)
           |> get_in(["error", "code"]) == "secure_transport_required"

    assert build_conn()
           |> put_req_header("content-type", "application/webhook+json")
           |> post("/api/v1/telephony/livekit/webhook", "{}")
           |> json_response(426)

    assert Repo.aggregate(Call, :count) == 0
  end

  test "unanswered inbound calls remain visible in durable history", %{
    account: account,
    token: token
  } do
    provision(account)
    event = incoming_event("missed-http-test")
    assert webhook(Jason.encode!(event)) |> json_response(200)

    finished = %{
      "event" => "room_finished",
      "id" => "missed-finished-http-test",
      "createdAt" => Integer.to_string(System.system_time(:second)),
      "room" => event["room"]
    }

    assert webhook(Jason.encode!(finished)) |> json_response(200)

    history =
      authenticated(token)
      |> get("/api/v1/telephony/calls")
      |> json_response(200)
      |> schema_fixture("list-history")

    assert [call] = history["data"]
    assert call["status"] == "no_answer"
    assert call["answered_at"] == nil
    assert call["connected_seconds"] == 0
  end

  test "outbound HTTP retries reuse the call and join only its scoped media room", %{
    account: account,
    token: token
  } do
    provision(account)

    config =
      authenticated(token)
      |> get("/api/v1/telephony/config")
      |> json_response(200)
      |> schema_fixture("config-ready")

    assert config["data"]["enabled"]
    assert config["data"]["configured"]
    assert config["data"]["provider_ready"]
    assert config["data"]["line_assigned"]
    attrs = %{destination: "+15550001002", idempotency_key: Ecto.UUID.generate()}

    started =
      authenticated(token)
      |> post("/api/v1/telephony/calls", attrs)
      |> json_response(201)
      |> schema_fixture("start")

    replayed =
      authenticated(token)
      |> post("/api/v1/telephony/calls", attrs)
      |> json_response(200)
      |> schema_fixture("start-replayed")

    assert started["data"]["id"] == replayed["data"]["id"]
    assert started["data"]["status"] == "ringing"
    assert Repo.aggregate(Call, :count) == 1

    joined =
      authenticated(token)
      |> post("/api/v1/telephony/calls/#{started["data"]["id"]}/join", %{})
      |> json_response(200)
      |> schema_fixture("join")

    started_claims = participant_claims(started["credential"]["participant_token"])
    joined_claims = participant_claims(joined["credential"]["participant_token"])
    assert started_claims["sub"] == joined_claims["sub"]
    assert started_claims["video"]["room"] == joined_claims["video"]["room"]

    ended =
      authenticated(token)
      |> post("/api/v1/telephony/calls/#{started["data"]["id"]}/end", %{})
      |> json_response(200)
      |> schema_fixture("end-cancelled")

    assert ended["data"]["status"] == "cancelled"
    assert ended["data"]["connected_seconds"] == 0
  end

  test "rejecting an incoming call persists its declined outcome without a credential", %{
    account: account,
    token: token
  } do
    provision(account)
    assert webhook(Jason.encode!(incoming_event("reject-http-test"))) |> json_response(200)
    history = authenticated(token) |> get("/api/v1/telephony/calls") |> json_response(200)
    assert [call] = history["data"]

    rejected =
      authenticated(token)
      |> post("/api/v1/telephony/calls/#{call["id"]}/reject", %{})
      |> json_response(200)
      |> schema_fixture("reject")

    assert rejected["data"]["status"] == "declined"
    assert rejected["data"]["connected_seconds"] == 0
    refute Map.has_key?(rejected, "credential")
  end

  test "a signed terminal event arriving first prevents a delayed incoming ring", %{
    account: account,
    token: token
  } do
    provision(account)
    event = incoming_event("left-first-http-test")
    terminal = Map.put(event, "event", "participant_left")
    assert webhook(Jason.encode!(terminal)) |> json_response(200)

    late_joined = Map.put(event, "id", "late-joined-http-test")
    assert webhook(Jason.encode!(late_joined)) |> json_response(200)

    active =
      authenticated(token)
      |> get("/api/v1/telephony/calls", %{scope: "active"})
      |> json_response(200)

    assert active["data"] == []

    history = authenticated(token) |> get("/api/v1/telephony/calls") |> json_response(200)
    assert [call] = history["data"]
    assert call["status"] == "no_answer"
    assert call["can_answer"] == false
    assert call["connected_seconds"] == 0
  end

  defp authenticated(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp schema_fixture(response, name) do
    if directory = System.get_env("TELEPHONY_SCHEMA_FIXTURES_DIR") do
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
      path = Path.join(directory, name <> ".json")
      File.write!(path, Jason.encode!(mask_fixture_credentials(response), pretty: true))
      File.chmod!(path, 0o600)
    end

    response
  end

  defp mask_fixture_credentials(value) when is_map(value) do
    Map.new(value, fn
      {"participant_token", _token} -> {"participant_token", "synthetic-participant-token"}
      {key, nested} -> {key, mask_fixture_credentials(nested)}
    end)
  end

  defp mask_fixture_credentials(value) when is_list(value),
    do: Enum.map(value, &mask_fixture_credentials/1)

  defp mask_fixture_credentials(value), do: value

  defp provision(account) do
    Application.put_env(:comms_integrations, :telephony_provider_mode, "livekit")
    Fixtures.step_up(account)
    assert {:ok, _} = Telephony.provision(number_attrs(account), Fixtures.subject(account))
  end

  defp incoming_event(id) do
    %{
      "event" => "participant_joined",
      "id" => id,
      "createdAt" => Integer.to_string(System.system_time(:second)),
      "room" => %{"name" => "kc_tel_inbound_#{id}"},
      "participant" => %{
        "kind" => "SIP",
        "sid" => "PA_sip_#{id}",
        "identity" => "sip-#{id}",
        "attributes" => %{
          "sip.trunkID" => "ST_inbound_test",
          "sip.phoneNumber" => "+15550001002",
          "sip.trunkPhoneNumber" => "+15550001001",
          "sip.callID" => "provider-#{id}",
          "sip.callStatus" => "ringing"
        }
      }
    }
  end

  defp webhook(body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> webhook_token(body))
    |> put_req_header("content-type", "application/webhook+json")
    |> post("/api/v1/telephony/livekit/webhook", body)
  end

  defp webhook_token(body) do
    encode = fn value -> value |> Jason.encode!() |> Base.url_encode64(padding: false) end
    header = encode.(%{alg: "HS256", typ: "JWT"})

    payload =
      encode.(%{
        iss: Application.fetch_env!(:comms_integrations, :livekit_api_key),
        exp: System.system_time(:second) + 60,
        sha256: Base.encode64(:crypto.hash(:sha256, body))
      })

    unsigned = header <> "." <> payload

    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        Application.fetch_env!(:comms_integrations, :livekit_api_secret),
        unsigned
      )

    unsigned <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp participant_claims(token) do
    [_header, payload, _signature] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp number_attrs(account) do
    %{
      user_id: account.user.id,
      phone_number: "+15550001001",
      extension: "101",
      inbound_trunk_id: "ST_inbound_test",
      outbound_trunk_id: "ST_outbound_test",
      reason: "Assign the synthetic test line"
    }
  end
end
