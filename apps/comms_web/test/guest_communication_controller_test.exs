defmodule CommsWeb.GuestCommunicationControllerTest.RoomService do
  def delete_room(provider_room) when is_binary(provider_room) do
    send(Application.fetch_env!(:comms_integrations, :guest_room_service_test_pid), {
      :delete_guest_room,
      provider_room
    })

    :ok
  end
end

defmodule CommsWeb.GuestCommunicationControllerTest do
  use CommsWeb.ConnCase, async: false

  require Phoenix.ChannelTest

  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Conversations.{GuestAdmission, GuestLink}
  alias CommsCore.Repo
  alias CommsIntegrations.Audio.LiveKitReadiness
  alias CommsTestSupport.Fixtures

  setup do
    {provider_socket, provider_port} = start_readiness_endpoint()

    provider_config = %{
      audio_provider_mode: "livekit",
      livekit_server_url: "wss://guest-media.example.test",
      livekit_api_url: "http://127.0.0.1:#{provider_port}",
      livekit_api_key: "guest-test-api-key",
      livekit_api_secret: "guest-test-api-secret",
      audio_token_ttl_seconds: 300,
      audio_room_service_adapter: CommsWeb.GuestCommunicationControllerTest.RoomService,
      guest_room_service_test_pid: self()
    }

    previous_provider_config =
      Map.new(provider_config, fn {key, _value} ->
        {key, Application.get_env(:comms_integrations, key)}
      end)

    Enum.each(provider_config, fn {key, value} ->
      Application.put_env(:comms_integrations, key, value)
    end)

    assert :ok = LiveKitReadiness.refresh()
    assert eventually(fn -> LiveKitReadiness.ensure_available() == :ok end)

    on_exit(fn ->
      :ok = :gen_tcp.close(provider_socket)

      Enum.each(previous_provider_config, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_integrations, key),
          else: Application.put_env(:comms_integrations, key, value)
      end)

      LiveKitReadiness.refresh()
    end)

    account = Fixtures.account_fixture()
    Fixtures.step_up(account)

    member_token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    {:ok, account: account, member_token: member_token}
  end

  test "one-time link preview and redemption create a strictly room-scoped guest session", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    old_message =
      member_conn(member_token)
      |> put_req_header("idempotency-key", "guest-history-before-0001")
      |> post("/api/v1/conversations/#{conversation_id}/messages", %{body: "Before guest"})
      |> json_response(201)

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 2
      })
      |> json_response(201)

    assert link["data"]["conversation_id"] == conversation_id
    assert link["data"]["remaining_uses"] == 2
    assert link["data"]["share_url"] =~ "/join#guest="
    assert link["share_url"] == link["data"]["share_url"]
    assert is_binary(link["token"])
    refute Map.has_key?(link, "conversion_verification_code")
    refute link["data"]["share_url"] =~ "code="

    preview =
      build_conn()
      |> post("/api/v1/guest-links/preview", %{token: link["token"]})
      |> json_response(200)

    assert preview == %{
             "data" => %{
               "room_title" => "General",
               "expires_at" => link["data"]["expires_at"],
               "conversion_enabled" => false,
               "email_hint" => nil
             }
           }

    refute inspect(preview) =~ account.tenant.id
    refute inspect(preview) =~ conversation_id

    session =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "External Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    assert session["user"]["account_type"] == "guest"
    assert session["user"]["display_name"] == "External Guest"
    refute Map.has_key?(session["user"], "email")
    assert session["conversation"]["id"] == conversation_id
    assert session["admission"]["guest_link_id"] == link["data"]["id"]

    assert session["admission"]["history_from_sequence"] >
             old_message["data"]["conversation_sequence"]

    assert session["capabilities"]["self_service_conversion"] == false
    assert is_binary(session["access_token"])
    assert is_binary(session["refresh_token"])

    guest_token = session["access_token"]

    assert member_conn(member_token)
           |> get("/api/v1/guest/conversation")
           |> response(401)

    assert guest_conn(guest_token) |> get("/api/v1/me") |> response(401)

    room =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation")
      |> json_response(200)

    assert room["data"]["id"] == conversation_id

    active_call =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation/call")
      |> json_response(200)

    assert active_call["data"] == nil

    members =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation/members")
      |> json_response(200)

    assert Enum.any?(members["data"], &(&1["user"]["id"] == session["user"]["id"]))

    assert Enum.all?(members["data"], fn membership ->
             Map.keys(membership["user"]) |> Enum.sort() ==
               ~w(account_type display_name id role status)
           end)

    history =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation/messages?after_sequence=0")
      |> json_response(200)

    refute Enum.any?(history["data"], &(&1["id"] == old_message["data"]["id"]))

    substituted_conversation_id = Ecto.UUID.generate()

    sent =
      guest_conn(guest_token)
      |> put_req_header("idempotency-key", "guest-message-send-0001")
      |> post("/api/v1/guest/conversation/messages", %{
        body: "Hello from the guest",
        conversation_id: substituted_conversation_id,
        tenant_id: Ecto.UUID.generate(),
        sender_user_id: Ecto.UUID.generate()
      })
      |> json_response(201)

    assert sent["data"]["conversation_id"] == conversation_id
    assert sent["data"]["sender_user_id"] == session["user"]["id"]

    cursor =
      guest_conn(guest_token)
      |> put("/api/v1/guest/conversation/read-cursor", %{
        sequence: sent["data"]["conversation_sequence"],
        conversation_id: substituted_conversation_id
      })
      |> json_response(200)

    assert cursor["data"]["sequence"] == sent["data"]["conversation_sequence"]

    socket_ticket =
      guest_conn(guest_token)
      |> post("/api/v1/guest/socket-tickets", %{})
      |> json_response(201)

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{
               "socket_ticket" => socket_ticket["data"]["ticket"]
             })

    assert socket.assigns.account_type == :guest
    assert socket.assigns.guest_conversation_id == conversation_id
    assert socket.assigns.guest_admission_id == session["admission"]["id"]

    assert {:error, %{reason: "forbidden"}} =
             CommsWeb.UserChannel.join("user:#{session["user"]["id"]}", %{}, socket)

    assert {:error, %{reason: "forbidden"}} =
             CommsWeb.ConversationChannel.join(
               "conversation:#{Ecto.UUID.generate()}",
               %{},
               socket
             )

    assert {:ok, replay, _socket} =
             CommsWeb.ConversationChannel.join(
               "conversation:#{conversation_id}",
               %{"after_sequence" => 0},
               socket
             )

    refute Enum.any?(replay.messages, &(&1.id == old_message["data"]["id"]))
    assert Enum.any?(replay.messages, &(&1.id == sent["data"]["id"]))

    expired_socket = %{
      socket
      | assigns:
          Map.put(
            socket.assigns,
            :guest_expires_at,
            DateTime.utc_now() |> DateTime.add(-1, :second)
          )
    }

    assert {:error, %{reason: "forbidden"}} =
             CommsWeb.ConversationChannel.join(
               "conversation:#{conversation_id}",
               %{},
               expired_socket
             )

    refreshed =
      build_conn()
      |> post("/api/v1/guest/sessions/refresh", %{refresh_token: session["refresh_token"]})
      |> json_response(200)

    assert refreshed["conversation"]["id"] == conversation_id
    assert refreshed["user"]["id"] == session["user"]["id"]
    assert refreshed["admission"]["guest_link_id"] == link["data"]["id"]
    assert refreshed["capabilities"]["self_service_conversion"] == false
    assert is_binary(refreshed["access_token"])
    assert refreshed["refresh_token"] != session["refresh_token"]

    assert guest_conn(refreshed["access_token"])
           |> delete("/api/v1/guest/sessions/current")
           |> response(204)

    assert guest_conn(refreshed["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(401)
  end

  test "optional conversion returns normal account access and preserves room membership", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id
    conversion_email = "converted-#{System.unique_integer([:positive])}@example.test"

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: conversion_email
      })
      |> json_response(201)

    guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "Convertible Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    refute inspect(guest) =~ link["conversion_verification_code"]

    converted =
      guest_conn(guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: conversion_email,
        verification_code: link["conversion_verification_code"],
        password: "correct-converted-guest-password-123",
        display_name: "Converted Member",
        device: %{name: "Converted browser", platform: "test"}
      })
      |> json_response(200)

    assert converted["authentication"]["user"]["id"] == guest["user"]["id"]
    assert converted["authentication"]["user"]["account_type"] == "human"
    refute Map.has_key?(converted["authentication"], "capabilities")
    assert converted["conversation"]["id"] == conversation_id

    normal_token = converted["authentication"]["access_token"]

    identity =
      member_conn(normal_token)
      |> get("/api/v1/me")
      |> json_response(200)

    assert identity["user"]["id"] == guest["user"]["id"]
    assert identity["user"]["account_type"] == "human"

    assert identity["capabilities"] == %{
             "allow_audio_calls" => true,
             "allow_public_channels" => true,
             "allow_video_calls" => true,
             "max_attachment_bytes" => 26_214_400,
             "message_edit_window_seconds" => 86_400
           }

    preserved =
      member_conn(normal_token)
      |> get("/api/v1/conversations/#{conversation_id}")
      |> json_response(200)

    assert preserved["data"]["id"] == conversation_id

    assert guest_conn(guest["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(401)

    member_conn(member_token)
    |> delete("/api/v1/conversations/#{conversation_id}/guest-links/#{link["data"]["id"]}")
    |> json_response(200)

    assert member_conn(normal_token)
           |> get("/api/v1/conversations/#{conversation_id}")
           |> response(200)
  end

  test "host link creation forwards the optional conversion email into domain policy", %{
    account: account,
    member_token: member_token
  } do
    conversion_email = "Invited.Guest+#{System.unique_integer([:positive])}@Example.Test"

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{account.conversation.id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: conversion_email
      })
      |> json_response(201)

    persisted = Repo.get!(GuestLink, link["data"]["id"])
    assert persisted.conversion_email == String.downcase(conversion_email)
    assert byte_size(link["conversion_verification_code"]) == 43

    assert {:ok, verification_secret} =
             Base.url_decode64(link["conversion_verification_code"], padding: false)

    assert persisted.conversion_verification_digest ==
             conversion_verification_digest(verification_secret, persisted)

    refute inspect(persisted) =~ link["conversion_verification_code"]
    refute link["data"]["share_url"] =~ link["conversion_verification_code"]

    listed =
      member_conn(member_token)
      |> get("/api/v1/conversations/#{account.conversation.id}/guest-links")
      |> json_response(200)

    refute inspect(listed) =~ link["conversion_verification_code"]

    preview =
      build_conn()
      |> post("/api/v1/guest-links/preview", %{token: link["token"]})
      |> json_response(200)

    refute inspect(preview) =~ link["conversion_verification_code"]

    invalid_use_count =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{account.conversation.id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 2,
        conversion_email: "single-use-only@example.test"
      })
      |> json_response(422)

    assert invalid_use_count["error"]["code"] ==
             "guest_account_conversion_requires_single_use"
  end

  test "account conversion requires the link's preauthorized email", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    communication_only =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    communication_guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: communication_only["token"],
        display_name: "Communication Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    disabled =
      guest_conn(communication_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: "not-authorized@example.test",
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    assert disabled["error"]["code"] == "guest_account_conversion_not_enabled"

    authorized_email = "authorized-#{System.unique_integer([:positive])}@example.test"

    account_link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: authorized_email
      })
      |> json_response(201)

    account_guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: account_link["token"],
        display_name: "Account Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    mismatch =
      guest_conn(account_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: "different@example.test",
        verification_code: account_link["conversion_verification_code"],
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    assert mismatch["error"]["code"] == "guest_account_conversion_email_mismatch"
    refute inspect(mismatch) =~ authorized_email

    missing_code =
      guest_conn(account_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: authorized_email,
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    wrong_code =
      guest_conn(account_guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: authorized_email,
        verification_code: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        password: "correct-converted-guest-password-123"
      })
      |> json_response(403)

    assert missing_code == wrong_code

    assert missing_code["error"]["code"] ==
             "guest_account_conversion_verification_failed"

    refute inspect([missing_code, wrong_code]) =~ authorized_email
  end

  test "guest account conversion is capped at five expensive attempts per minute", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id
    conversion_email = "rate-limited-#{System.unique_integer([:positive])}@example.test"

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: conversion_email
      })
      |> json_response(201)

    guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "Rate Limited Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    for _attempt <- 1..5 do
      response =
        guest_conn(guest["access_token"])
        |> post("/api/v1/guest/account", %{
          email: conversion_email,
          verification_code: link["conversion_verification_code"],
          password: "correct-converted-guest-password-123",
          display_name: "",
          device: %{name: "Converted browser", platform: "test"}
        })
        |> json_response(422)

      assert response["error"]["code"] == "invalid_guest_account"
    end

    response =
      guest_conn(guest["access_token"])
      |> post("/api/v1/guest/account", %{
        email: conversion_email,
        verification_code: link["conversion_verification_code"],
        password: "correct-converted-guest-password-123",
        display_name: "",
        device: %{name: "Converted browser", platform: "test"}
      })
      |> json_response(429)

    assert response["error"]["code"] == "rate_limited"
  end

  test "guest-scoped routes start, join, and end audio and video calls", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "Calling Guest",
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    authority_deadline = DateTime.utc_now() |> DateTime.add(120, :second)
    session_deadline = DateTime.add(authority_deadline, -30, :second)
    bound_guest_authority!(guest, link, authority_deadline, session_deadline)
    substituted_conversation_id = Ecto.UUID.generate()

    for {media_kind, expected_sources} <- [
          {"audio", ["microphone"]},
          {"video", ["microphone", "camera", "screen_share", "screen_share_audio"]}
        ] do
      started =
        guest_conn(guest["access_token"])
        |> post("/api/v1/guest/conversation/calls", %{
          media_kind: media_kind,
          conversation_id: substituted_conversation_id
        })
        |> json_response(201)

      assert started["data"]["conversation_id"] == conversation_id
      assert started["data"]["media_kind"] == media_kind
      assert started["data"]["started_by_user_id"] == guest["user"]["id"]
      assert started["credential"]["server_url"] == "wss://guest-media.example.test"
      assert started["credential"]["expires_in"] in 1..90

      [_header, encoded_claims, _signature] =
        String.split(started["credential"]["participant_token"], ".")

      claims =
        encoded_claims
        |> Base.url_decode64!(padding: false)
        |> Jason.decode!()

      assert claims["exp"] <= DateTime.to_unix(session_deadline, :second)
      assert claims["video"]["canPublishSources"] == expected_sources

      call_id = started["data"]["id"]

      joined =
        guest_conn(guest["access_token"])
        |> post("/api/v1/guest/conversation/calls/#{call_id}/join", %{
          conversation_id: substituted_conversation_id
        })
        |> json_response(200)

      assert joined["data"]["id"] == call_id
      assert joined["data"]["media_kind"] == media_kind
      assert joined["credential"]["expires_in"] in 1..90

      ended =
        guest_conn(guest["access_token"])
        |> post("/api/v1/guest/conversation/calls/#{call_id}/end", %{
          conversation_id: substituted_conversation_id,
          reason: "owner_ended"
        })
        |> json_response(200)

      assert_receive {:delete_guest_room, provider_room}
      assert is_binary(provider_room)
      assert ended["data"]["id"] == call_id
      assert ended["data"]["status"] == "ended"
      assert ended["data"]["media_kind"] == media_kind
    end
  end

  test "invalid, exhausted, revoked, and unknown links share one public error", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    member_conn(member_token)
    |> delete("/api/v1/conversations/#{conversation_id}/guest-links/#{link["data"]["id"]}")
    |> json_response(200)

    revoked =
      build_conn()
      |> post("/api/v1/guest-links/preview", %{token: link["token"]})
      |> json_response(404)

    unknown =
      build_conn()
      |> post("/api/v1/guest-links/preview", %{
        token:
          "#{Ecto.UUID.generate()}.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
      })
      |> json_response(404)

    assert revoked == unknown

    assert revoked == %{
             "error" => %{
               "code" => "guest_link_unavailable",
               "detail" => "This guest communication link is unavailable"
             }
           }
  end

  defp member_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp guest_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp bound_guest_authority!(guest, link, authority_deadline, session_deadline) do
    guest_user =
      User
      |> Repo.get!(guest["user"]["id"])
      |> Ecto.Changeset.change(guest_expires_at: authority_deadline)
      |> Repo.update!()

    Session
    |> Repo.get_by!(user_id: guest_user.id)
    |> Ecto.Changeset.change(expires_at: session_deadline)
    |> Repo.update!()

    GuestLink
    |> Repo.get!(link["data"]["id"])
    |> Ecto.Changeset.change(expires_at: authority_deadline)
    |> Repo.update!()

    GuestAdmission
    |> Repo.get!(guest["admission"]["id"])
    |> Ecto.Changeset.change(expires_at: authority_deadline)
    |> Repo.update!()
  end

  defp start_readiness_endpoint do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    spawn_link(fn -> serve_readiness(listener) end)
    {listener, port}
  end

  defp serve_readiness(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 12\r\nconnection: close\r\n\r\n{\"rooms\":[]}"
          )

        :gen_tcp.close(socket)
        serve_readiness(listener)

      {:error, :closed} ->
        :ok
    end
  end

  defp eventually(fun, attempts \\ 80)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp conversion_verification_digest(secret, link) do
    :crypto.hash(:sha256, [
      "k-comms:guest-conversion-verification:v1",
      <<0>>,
      link.tenant_id,
      <<0>>,
      link.conversation_id,
      <<0>>,
      link.id,
      <<0>>,
      link.conversion_email,
      <<0>>,
      secret
    ])
  end
end
