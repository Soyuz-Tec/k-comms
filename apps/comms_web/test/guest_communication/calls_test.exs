defmodule CommsWeb.GuestCommunication.CallsTest do
  use CommsWeb.ConnCase, async: false

  import CommsWeb.GuestCommunicationTestSupport

  @moduletag :integration
  @moduletag :guest
  @moduletag :call

  setup :setup_account
  setup {CommsWeb.GuestCommunicationMediaTestSupport, :setup_livekit}

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
end
