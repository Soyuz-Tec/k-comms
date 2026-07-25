defmodule CommsWeb.InstantRoomControllerTest do
  use CommsWeb.ConnCase, async: false

  import Ecto.Query

  require Phoenix.ChannelTest

  alias CommsCore.Accounts.Session
  alias CommsCore.Conversations

  alias CommsCore.Conversations.{
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestAdmission,
    Membership
  }

  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @origin "http://localhost:5173"

  setup do
    account = Fixtures.account_fixture()

    settings = %{
      instant_rooms_enabled: true,
      instant_room_tenant_slug: account.tenant.slug,
      instant_room_guest_idle_ttl_seconds: 3_600,
      instant_room_registered_idle_ttl_seconds: 86_400,
      instant_room_presence_heartbeat_seconds: 30,
      instant_room_presence_lease_seconds: 90,
      instant_room_reconnect_grace_seconds: 90,
      instant_room_max_participants: 5
    }

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.get_env(:comms_core, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_core, key),
          else: Application.put_env(:comms_core, key, value)
      end)
    end)

    {:ok, account: account}
  end

  test "anonymous creation, replay, preview, and guest join form a complete public flow", %{
    account: _account
  } do
    create_key = idempotency_key()

    create_body = %{
      display_name: "Instant host",
      title: "Customer room",
      device: %{name: "Host browser", platform: "web"}
    }

    created =
      build_conn()
      |> public_json_headers(create_key)
      |> post("/api/v1/instant-rooms", Jason.encode!(create_body))

    assert get_resp_header(created, "cache-control") == ["no-store"]

    response = json_response(created, 201)
    assert response["replayed"] == false
    assert response["room"]["status"] == "active"
    assert response["room"]["owner_kind"] == "guest"
    assert response["room"]["conversation_id"] == response["conversation"]["id"]

    assert Map.keys(response["room"]) |> Enum.sort() ==
             ~w(conversation_id expires_at id idle_since inserted_at owner_kind owner_user_id participant_limit status updated_at)

    refute Map.has_key?(response["room"], "generation")
    refute Map.has_key?(response["room"], "reconnect_grace_seconds")
    refute Map.has_key?(response["room"], "last_presence_at")
    assert response["user"]["account_type"] == "guest"
    assert response["user"]["access_scope"] == "conversation_only"
    assert response["capabilities"]["self_service_conversion"] == true
    assert is_binary(response["access_token"])
    assert is_binary(response["refresh_token"])
    assert is_binary(response["token"])

    assert response["share_url"] ==
             "#{Application.fetch_env!(:comms_core, :public_app_url) |> String.trim_trailing("/")}/join#guest=#{URI.encode_www_form(response["token"])}"

    refute response["share_url"] =~ "?token="

    replayed =
      build_conn()
      |> public_json_headers(create_key)
      |> post("/api/v1/instant-rooms", Jason.encode!(create_body))
      |> json_response(200)

    assert replayed["replayed"] == true
    assert replayed["room"]["id"] == response["room"]["id"]
    assert replayed["conversation"]["id"] == response["conversation"]["id"]

    preview =
      build_conn()
      |> public_json_headers()
      |> post(
        "/api/v1/instant-rooms/preview",
        Jason.encode!(%{token: response["token"]})
      )
      |> json_response(200)

    assert preview["data"]["room_title"] == "Customer room"
    assert preview["data"]["status"] == "active"

    assert Map.keys(preview["data"]) |> Enum.sort() ==
             ~w(expires_at participant_limit room_title status)

    conversation_topic = "conversation:#{response["conversation"]["id"]}"
    assert :ok = CommsWeb.Endpoint.subscribe(conversation_topic)
    join_key = idempotency_key()

    joined =
      build_conn()
      |> public_json_headers(join_key)
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: response["token"],
          display_name: "Instant guest",
          device: %{name: "Guest browser", platform: "web"}
        })
      )
      |> json_response(201)

    assert joined["room"]["id"] == response["room"]["id"]
    assert joined["conversation"]["id"] == response["conversation"]["id"]
    assert joined["user"]["account_type"] == "guest"
    assert joined["user"]["access_scope"] == "conversation_only"
    assert joined["user"]["id"] != response["user"]["id"]
    assert joined["capabilities"]["self_service_conversion"] == true

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^conversation_topic,
      event: "membership.changed.v1",
      payload: %{
        user_id: joined_user_id,
        action: "added",
        role: :member,
        source: "guest_link"
      }
    }

    assert joined_user_id == joined["user"]["id"]
    refute_received %Phoenix.Socket.Broadcast{topic: ^conversation_topic}

    replayed_join =
      build_conn()
      |> public_json_headers(join_key)
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: response["token"],
          display_name: "Instant guest",
          device: %{name: "Guest browser", platform: "web"}
        })
      )
      |> json_response(200)

    assert replayed_join["replayed"] == true
    assert replayed_join["user"]["id"] == joined["user"]["id"]
    refute_receive %Phoenix.Socket.Broadcast{topic: ^conversation_topic}, 50

    refreshed =
      build_conn()
      |> post("/api/v1/guest/sessions/refresh", %{
        refresh_token: replayed_join["refresh_token"]
      })
      |> json_response(200)

    assert refreshed["user"]["id"] == joined["user"]["id"]
    assert refreshed["conversation"]["id"] == joined["conversation"]["id"]
    assert refreshed["capabilities"]["self_service_conversion"] == true
  end

  test "human creation preserves existing authentication", %{account: account} do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    response =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{title: "Registered host room"})
      )
      |> json_response(201)

    assert response["room"]["owner_kind"] == "registered"
    assert response["conversation"]["id"] == response["room"]["conversation_id"]
    assert is_binary(response["share_url"])
    refute Map.has_key?(response, "access_token")
    refute Map.has_key?(response, "refresh_token")
  end

  test "anonymous creation rejects a missing display name" do
    response =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{device: %{name: "Host browser", platform: "web"}})
      )

    assert json_response(response, 422)["error"]["code"] == "invalid_guest_display_name"
  end

  test "a fresh human join for an already-active membership emits no added event", %{
    account: account
  } do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    created =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{title: "Existing member room"})
      )
      |> json_response(201)

    conversation_topic = "conversation:#{created["conversation"]["id"]}"
    assert :ok = CommsWeb.Endpoint.subscribe(conversation_topic)

    joined =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{token: created["token"]})
      )
      |> json_response(201)

    assert joined["replayed"] == false

    refute_receive %Phoenix.Socket.Broadcast{
                     topic: ^conversation_topic,
                     event: "membership.changed.v1"
                   },
                   50
  end

  test "a cross-tenant human falls back to a public-workspace guest without selecting a tenant",
       %{
         account: public_account
       } do
    other_tenant_account = Fixtures.account_fixture()

    token =
      other_tenant_account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    response =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/instant-rooms", Jason.encode!(%{title: "Cross-tenant room"}))
      |> json_response(201)

    assert response["room"]["owner_kind"] == "guest"
    assert response["tenant"]["id"] == public_account.tenant.id
    assert response["user"]["id"] != other_tenant_account.user.id
    assert response["user"]["display_name"] == other_tenant_account.user.display_name
    assert is_binary(response["access_token"])
  end

  test "a same-tenant conversation-only human reuses its registered identity for creation and join",
       %{
         account: public_account
       } do
    original_guest =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Original guest",
          device: %{name: "Verified browser", platform: "web"}
        })
      )
      |> json_response(201)

    converted =
      build_conn()
      |> put_req_header("authorization", "Bearer #{original_guest["access_token"]}")
      |> post("/api/v1/guest/account", %{
        email: "scoped-#{System.unique_integer([:positive])}@example.test",
        password: "correct-conversation-scoped-password-123",
        display_name: "Verified converted user",
        device: %{name: "Verified browser", platform: "web"}
      })
      |> json_response(200)

    converted_token = converted["authentication"]["access_token"]
    converted_user_id = converted["authentication"]["user"]["id"]

    created =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{converted_token}")
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Untrusted override",
          title: "Scoped-user room",
          device: %{name: "Untrusted device", platform: "unknown"}
        })
      )
      |> json_response(201)

    assert created["room"]["owner_kind"] == "registered"
    assert created["room"]["owner_user_id"] == converted_user_id
    refute Map.has_key?(created, "tenant")
    refute Map.has_key?(created, "user")
    refute Map.has_key?(created, "device")
    refute Map.has_key?(created, "access_token")
    refute Map.has_key?(created, "refresh_token")
    refute Map.has_key?(created, "admission")

    target =
      %{build_conn() | remote_ip: {198, 51, 100, 177}}
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Other guest host",
          device: %{name: "Other browser", platform: "web"}
        })
      )
      |> json_response(201)

    target_conversation_id = target["conversation"]["id"]
    join_key = idempotency_key()

    joined =
      build_conn()
      |> public_json_headers(join_key)
      |> put_req_header("authorization", "Bearer #{converted_token}")
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: target["token"],
          display_name: "Untrusted join override",
          device: %{name: "Untrusted join device", platform: "unknown"}
        })
      )
      |> json_response(201)

    assert joined["room"]["id"] == target["room"]["id"]
    refute Map.has_key?(joined, "user")
    refute Map.has_key?(joined, "device")
    refute Map.has_key?(joined, "access_token")
    refute Map.has_key?(joined, "refresh_token")
    refute Map.has_key?(joined, "admission")

    assert %Membership{role: :member, left_at: nil} =
             Repo.get_by!(Membership,
               conversation_id: target_conversation_id,
               user_id: converted_user_id
             )

    refute Repo.exists?(
             from(admission in GuestAdmission,
               where:
                 admission.conversation_id == ^target_conversation_id and
                   admission.guest_user_id == ^converted_user_id
             )
           )

    replayed =
      build_conn()
      |> public_json_headers(join_key)
      |> put_req_header("authorization", "Bearer #{converted_token}")
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{token: target["token"]})
      )
      |> json_response(200)

    assert replayed["replayed"] == true
    assert replayed["room"]["id"] == target["room"]["id"]

    assert Repo.aggregate(
             from(membership in Membership,
               where:
                 membership.conversation_id == ^target_conversation_id and
                   membership.user_id == ^converted_user_id
             ),
             :count
           ) == 1

    assert Repo.get!(EphemeralRoom, created["room"]["id"]).tenant_id == public_account.tenant.id
  end

  test "the creator can upgrade in place and receives a realtime socket handoff" do
    guest =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Future member",
          device: %{name: "Upgrade browser", platform: "web"}
        })
      )
      |> json_response(201)

    socket_ticket =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> post("/api/v1/guest/socket-tickets", %{})
      |> json_response(201)

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{
               "socket_ticket" => socket_ticket["data"]["ticket"]
             })

    session_topic = "session_socket:#{socket.assigns.session_id}"
    assert :ok = CommsWeb.Endpoint.subscribe(session_topic)

    converted =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> post("/api/v1/guest/account", %{
        email: "instant-#{System.unique_integer([:positive])}@example.test",
        password: "correct-instant-room-password-123",
        display_name: "Converted instant member",
        device: %{name: "Upgrade browser", platform: "web"}
      })
      |> json_response(200)

    assert converted["authentication"]["user"]["id"] == guest["user"]["id"]
    assert converted["authentication"]["user"]["account_type"] == "human"
    assert converted["authentication"]["user"]["access_scope"] == "conversation_only"
    assert converted["conversation"]["id"] == guest["conversation"]["id"]
    assert is_binary(converted["socket_handoff"]["ticket"])
    assert is_integer(converted["socket_handoff"]["expires_in"])
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50
  end

  test "ephemeral logout atomically closes only the departing guest scope" do
    host =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Remaining host",
          device: %{name: "Host browser", platform: "web"}
        })
      )
      |> json_response(201)

    joined =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: host["token"],
          display_name: "Departing guest",
          device: %{name: "Guest browser", platform: "web"}
        })
      )
      |> json_response(201)

    assert {:ok, %{context: host_context}} =
             CommsWeb.GuestToken.verify(host["access_token"], "host-presence")

    assert {:ok, %{context: joined_context}} =
             CommsWeb.GuestToken.verify(joined["access_token"], "joined-presence")

    host_presence =
      host_context.subject
      |> Map.put(:conversation_id, host["conversation"]["id"])
      |> Map.put(:connection_id, idempotency_key())

    joined_presence =
      joined_context.subject
      |> Map.put(:conversation_id, host["conversation"]["id"])
      |> Map.put(:connection_id, idempotency_key())

    assert {:ok, host_opened} = Conversations.open_ephemeral_presence(host_presence)
    assert {:ok, joined_opened} = Conversations.open_ephemeral_presence(joined_presence)

    session_topic = "session_socket:#{joined_context.subject.session_id}"
    assert :ok = CommsWeb.Endpoint.subscribe(session_topic)

    assert guest_conn(joined["access_token"])
           |> delete("/api/v1/guest/sessions/current")
           |> response(204)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^session_topic,
      event: "disconnect"
    }

    joined_admission = Repo.get!(GuestAdmission, joined["admission"]["id"])
    assert %GuestAdmission{revoked_at: %DateTime{}} = joined_admission

    assert %Membership{left_at: %DateTime{}} =
             Repo.get!(Membership, joined_admission.membership_id)

    assert %Session{revoked_at: %DateTime{}} =
             Repo.get!(Session, joined_context.subject.session_id)

    assert %EphemeralPresenceLease{closed_at: %DateTime{}} =
             Repo.get!(EphemeralPresenceLease, joined_opened.lease.id)

    host_admission = Repo.get!(GuestAdmission, host["admission"]["id"])
    assert %GuestAdmission{revoked_at: nil} = host_admission

    assert %Membership{left_at: nil} =
             Repo.get!(Membership, host_admission.membership_id)

    assert %Session{revoked_at: nil} =
             Repo.get!(Session, host_context.subject.session_id)

    assert %EphemeralPresenceLease{closed_at: nil} =
             Repo.get!(EphemeralPresenceLease, host_opened.lease.id)

    assert %EphemeralRoom{status: :active} = Repo.get!(EphemeralRoom, host["room"]["id"])

    assert guest_conn(host["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(200)

    assert build_conn()
           |> public_json_headers()
           |> post(
             "/api/v1/instant-rooms/preview",
             Jason.encode!(%{token: host["token"]})
           )
           |> response(200)

    assert guest_conn(joined["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(401)
  end

  test "HTTP messages share the per-identity instant-room distributed limit" do
    guest =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Rate limited guest",
          device: %{name: "Rate browser", platform: "web"}
        })
      )
      |> json_response(201)

    assert {:ok, %{context: context}} =
             CommsWeb.GuestToken.verify(guest["access_token"], "rate-limit-test")

    key_digest =
      CommsWeb.Plugs.DistributedRateLimit.key_digest(:instant_room_message, [
        "identity-room",
        0,
        context.subject.tenant_id,
        0,
        context.subject.user_id,
        0,
        context.subject.session_id,
        0,
        guest["conversation"]["id"]
      ])

    for _request <- 1..30 do
      assert %{allowed: true} =
               CommsCore.PlatformRateLimits.allow?(
                 :instant_room_message,
                 key_digest,
                 30,
                 60
               )
    end

    rejected =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> put_req_header("idempotency-key", "instant-http-message-0001")
      |> post("/api/v1/guest/conversation/messages", %{body: "blocked"})

    assert %{
             "error" => %{
               "code" => "rate_limited",
               "retry_after" => retry_after
             }
           } = json_response(rejected, 429)

    assert retry_after in 1..60
    assert get_resp_header(rejected, "retry-after") == [Integer.to_string(retry_after)]
  end

  test "public mutations fail closed before reaching the domain" do
    invalid_auth =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer invalid")
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(invalid_auth, 401)["error"]["code"] == "unauthenticated"

    missing_origin =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", idempotency_key())
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(missing_origin, 403)["error"]["code"] == "origin_required"

    invalid_key =
      build_conn()
      |> public_json_headers("not-a-256-bit-key")
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(invalid_key, 422)["error"]["code"] == "invalid_idempotency_key"

    noncanonical_key =
      build_conn()
      |> public_json_headers(String.duplicate("x", 43))
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(noncanonical_key, 422)["error"]["code"] == "invalid_idempotency_key"
  end

  test "malformed and unavailable join tokens use one indistinguishable response" do
    for token <- ["short", String.duplicate("x", 43)] do
      response =
        build_conn()
        |> public_json_headers()
        |> post("/api/v1/instant-rooms/preview", Jason.encode!(%{token: token}))

      assert json_response(response, 404) == %{
               "error" => %{
                 "code" => "instant_room_unavailable",
                 "detail" => "This instant communication room is unavailable"
               }
             }
    end
  end

  test "feature-off mode fails create, preview, and join closed" do
    Application.put_env(:comms_core, :instant_rooms_enabled, false)
    token = idempotency_key()

    requests = [
      {:create, "/api/v1/instant-rooms", %{display_name: "Disabled"}},
      {:preview, "/api/v1/instant-rooms/preview", %{token: token}},
      {:join, "/api/v1/instant-room-sessions", %{token: token, display_name: "Disabled"}}
    ]

    Enum.each(requests, fn {action, path, body} ->
      conn =
        build_conn()
        |> public_json_headers(if(action in [:create, :join], do: idempotency_key()))
        |> post(path, Jason.encode!(body))

      assert json_response(conn, 503)["error"]["code"] == "instant_rooms_unavailable"
    end)
  end

  defp public_json_headers(conn, idempotency_key \\ nil) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", @origin)

    if is_binary(idempotency_key),
      do: put_req_header(conn, "idempotency-key", idempotency_key),
      else: conn
  end

  defp idempotency_key do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp guest_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
