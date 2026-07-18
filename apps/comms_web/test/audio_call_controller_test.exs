defmodule CommsWeb.AudioCallControllerTest.RoomService do
  def delete_room(call) do
    send(Application.fetch_env!(:comms_integrations, :audio_room_service_test_pid), {
      :delete_audio_room,
      call.provider_room
    })

    Application.get_env(:comms_integrations, :audio_room_service_test_result, :ok)
  end
end

defmodule CommsWeb.AudioCallControllerTest do
  use CommsWeb.ConnCase, async: false

  import Ecto.Query

  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}
  alias CommsCore.Audit
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  setup do
    values = %{
      audio_provider_mode: "livekit",
      livekit_server_url: "wss://audio.example.test",
      livekit_api_url: "https://audio-api.example.test",
      livekit_api_key: "test-api-key",
      livekit_api_secret: "test-api-secret",
      audio_token_ttl_seconds: 300,
      audio_room_service_adapter: CommsWeb.AudioCallControllerTest.RoomService,
      audio_room_service_test_pid: self(),
      audio_room_service_test_result: :ok
    }

    previous =
      Map.new(values, fn {key, _value} -> {key, Application.get_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_integrations, key),
          else: Application.put_env(:comms_integrations, key, value)
      end)
    end)

    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    {:ok, account: account, authorization: {"authorization", "Bearer #{token}"}}
  end

  test "exact REST lifecycle returns memory-only credentials and broadcasts lifecycle metadata",
       %{
         account: account,
         authorization: authorization
       } do
    conversation_id = account.conversation.id
    assert :ok = CommsWeb.Endpoint.subscribe("conversation:#{conversation_id}")

    started =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls", %{})
      |> json_response(201)

    assert started["data"]["conversation_id"] == conversation_id
    assert started["data"]["status"] == "active"
    assert started["data"]["can_end"] == true
    refute Map.has_key?(started["data"], "provider_room")
    assert started["credential"]["server_url"] == "wss://audio.example.test"
    assert is_binary(started["credential"]["participant_token"])
    call_id = started["data"]["id"]

    assert_receive %Phoenix.Socket.Broadcast{
      event: "audio_call.started.v1",
      payload: payload
    }

    refute Map.has_key?(payload, :credential)
    refute Map.has_key?(payload, :provider_room)

    lookup =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> get("/api/v1/conversations/#{conversation_id}/audio-call")
      |> json_response(200)

    assert lookup["data"]["id"] == call_id
    assert lookup["data"]["can_end"] == true

    replay =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls", %{})
      |> json_response(200)

    assert replay["data"]["id"] == call_id

    joined =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls/#{call_id}/join", %{})
      |> json_response(200)

    assert joined["data"]["id"] == call_id
    assert joined["data"]["can_end"] == true
    assert joined["credential"]["participant_token"] != ""

    ended =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls/#{call_id}/end", %{
        reason: "owner_ended"
      })
      |> json_response(200)

    call = Repo.get!(AudioCall, call_id)
    assert_receive {:delete_audio_room, provider_room}
    assert provider_room == call.provider_room
    assert ended["data"]["status"] == "ended"
    assert ended["data"]["can_end"] == true
    refute inspect(call) =~ started["credential"]["participant_token"]

    refute Audit.list(%{tenant_id: call.tenant_id}) |> inspect() =~
             started["credential"]["participant_token"]

    refute Repo.all(OutboxEvent) |> inspect() =~ started["credential"]["participant_token"]

    assert_receive %Phoenix.Socket.Broadcast{
      event: "audio_call.ended.v1",
      payload: ended_payload
    }

    refute Map.has_key?(ended_payload, :credential)
    refute Map.has_key?(ended_payload, :can_end)
  end

  test "provider deletion failure leaves the call active and emits no ended broadcast", %{
    account: account,
    authorization: authorization
  } do
    conversation_id = account.conversation.id

    started =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls", %{})
      |> json_response(201)

    assert :ok = CommsWeb.Endpoint.subscribe("conversation:#{conversation_id}")

    Application.put_env(
      :comms_integrations,
      :audio_room_service_test_result,
      {:error, :audio_provider_unavailable}
    )

    build_conn()
    |> put_req_header(elem(authorization, 0), elem(authorization, 1))
    |> post(
      "/api/v1/conversations/#{conversation_id}/audio-calls/#{started["data"]["id"]}/end",
      %{}
    )
    |> json_response(503)

    assert Repo.get!(AudioCall, started["data"]["id"]).status == :active
    refute_receive %Phoenix.Socket.Broadcast{event: "audio_call.ended.v1"}
  end

  test "starting after expiry deletes the old provider room before creating a replacement", %{
    account: account,
    authorization: authorization
  } do
    conversation_id = account.conversation.id

    started =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls", %{})
      |> json_response(201)

    old_call = Repo.get!(AudioCall, started["data"]["id"])
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old_call
    |> Ecto.Changeset.change(%{
      started_at: DateTime.add(timestamp, -3_600),
      expires_at: DateTime.add(timestamp, -1)
    })
    |> Repo.update!()

    replacement =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls", %{})
      |> json_response(201)

    assert_receive {:delete_audio_room, provider_room}
    assert provider_room == old_call.provider_room
    refute replacement["data"]["id"] == old_call.id
    assert Repo.get!(AudioCall, old_call.id).status == :ended
    assert Repo.get!(AudioCall, replacement["data"]["id"]).status == :active
  end

  test "invalid end reason never deletes the provider room or ends the call", %{
    account: account,
    authorization: authorization
  } do
    conversation_id = account.conversation.id

    started =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls", %{})
      |> json_response(201)

    call_id = started["data"]["id"]
    assert :ok = CommsWeb.Endpoint.subscribe("conversation:#{conversation_id}")

    response =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls/#{call_id}/end", %{
        reason: "  "
      })
      |> json_response(422)

    assert response["error"]["code"] == "invalid_end_reason"
    refute_received {:delete_audio_room, _provider_room}
    assert Repo.get!(AudioCall, call_id).status == :active
    refute_receive %Phoenix.Socket.Broadcast{event: "audio_call.ended.v1"}
  end

  test "canonical REST lifecycle creates and joins video calls while audio aliases stay strict",
       %{
         account: account,
         authorization: authorization
       } do
    conversation_id = account.conversation.id
    assert :ok = CommsWeb.Endpoint.subscribe("conversation:#{conversation_id}")

    started =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/calls", %{media_kind: "video"})
      |> json_response(201)

    assert started["data"]["media_kind"] == "video"
    assert started["data"]["status"] == "active"
    call_id = started["data"]["id"]

    [_header, encoded_claims, _signature] =
      String.split(started["credential"]["participant_token"], ".")

    claims =
      encoded_claims
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()

    assert claims["video"]["canPublishSources"] == [
             "microphone",
             "camera",
             "screen_share",
             "screen_share_audio"
           ]

    assert claims["video"]["canPublishData"] == false
    assert claims["video"]["roomAdmin"] == false
    assert claims["video"]["roomRecord"] == false

    assert_receive %Phoenix.Socket.Broadcast{
      event: "call.started.v1",
      payload: %{media_kind: :video}
    }

    lookup =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> get("/api/v1/conversations/#{conversation_id}/call")
      |> json_response(200)

    assert lookup["data"]["id"] == call_id
    assert lookup["data"]["media_kind"] == "video"

    legacy_lookup =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> get("/api/v1/conversations/#{conversation_id}/audio-call")
      |> json_response(409)

    assert legacy_lookup["error"]["code"] == "call_media_kind_conflict"

    legacy_join =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls/#{call_id}/join", %{})
      |> json_response(409)

    assert legacy_join["error"]["code"] == "call_media_kind_conflict"

    joined =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/calls/#{call_id}/join", %{})
      |> json_response(200)

    assert joined["data"]["media_kind"] == "video"

    ended =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/calls/#{call_id}/end", %{
        reason: "owner_ended"
      })
      |> json_response(200)

    assert ended["data"]["status"] == "ended"

    assert_receive %Phoenix.Socket.Broadcast{
      event: "call.ended.v1",
      payload: %{media_kind: :video}
    }

    refute_receive %Phoenix.Socket.Broadcast{event: "audio_call.started.v1"}
    refute_receive %Phoenix.Socket.Broadcast{event: "audio_call.ended.v1"}
  end

  test "canonical call create validates media kind and tenant video capability", %{
    account: account,
    authorization: authorization
  } do
    conversation_id = account.conversation.id

    missing =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/calls", %{})
      |> json_response(422)

    assert missing["error"]["code"] == "invalid_media_kind"

    invalid =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/calls", %{media_kind: "data"})
      |> json_response(422)

    assert invalid["error"]["code"] == "invalid_media_kind"

    settings =
      Repo.get_by(CommsCore.Administration.TenantSettings, tenant_id: account.tenant.id) ||
        %CommsCore.Administration.TenantSettings{tenant_id: account.tenant.id}

    settings
    |> CommsCore.Administration.TenantSettings.changeset(%{allow_video_calls: false})
    |> Repo.insert_or_update!()

    disabled =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/calls", %{media_kind: "video"})
      |> json_response(403)

    assert disabled["error"]["code"] == "video_calls_disabled"

    legacy_video =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{conversation_id}/audio-calls", %{media_kind: "video"})
      |> json_response(422)

    assert legacy_video["error"]["code"] == "invalid_media_kind"
  end

  test "starter credential failure leaves no call, admission, event, audit, or expiry job", %{
    account: account,
    authorization: authorization
  } do
    from(user in CommsCore.Accounts.User, where: user.id == ^account.user.id)
    |> Repo.update_all(set: [display_name: ""])

    response =
      build_conn()
      |> put_req_header(elem(authorization, 0), elem(authorization, 1))
      |> post("/api/v1/conversations/#{account.conversation.id}/calls", %{
        media_kind: "video"
      })
      |> json_response(422)

    assert response["error"]["code"] == "audio_identity_invalid"
    assert Repo.aggregate(AudioCall, :count) == 0
    assert Repo.aggregate(AudioCallParticipant, :count) == 0

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where: event.event_type in ["call.started.v1", "audio_call.started.v1"]
             ),
             :count
           ) == 0

    assert Audit.count(%{tenant_id: account.tenant.id, action: "audio_call.start"}) == 0
    assert Audit.count(%{tenant_id: account.tenant.id, action: "video_call.start"}) == 0

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "CommsWorkers.AudioCallExpiryWorker"
             ),
             :count
           ) == 0
  end
end
