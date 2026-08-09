defmodule CommsWeb.CallChannelTest do
  use ExUnit.Case, async: false

  @moduletag :call
  @moduletag :integration

  import Phoenix.ChannelTest

  alias CommsCore.Accounts.Session
  alias CommsCore.{Accounts, AudioCalls, Conversations, Repo}
  alias CommsTestSupport.Fixtures
  alias CommsWeb.CallChannel

  @endpoint CommsWeb.Endpoint

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    previous_enabled = Application.get_env(:comms_web, :direct_audio_p2p_enabled)
    previous_urls = Application.get_env(:comms_web, :direct_audio_stun_urls)
    Application.put_env(:comms_web, :direct_audio_p2p_enabled, true)
    Application.put_env(:comms_web, :direct_audio_stun_urls, ["stun:stun.cloudflare.com:3478"])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      restore_env(:direct_audio_p2p_enabled, previous_enabled)
      restore_env(:direct_audio_stun_urls, previous_urls)
    end)

    :ok
  end

  test "an admitted participant raises a hand and sends bounded reactions" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:ok, ^call, _identity} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn request -> {:ok, request.provider_identity} end
             )

    socket = socket(CommsWeb.UserSocket, "call-owner", subject)

    assert {:ok, %{raised_user_ids: []}, socket} =
             subscribe_and_join(socket, CallChannel, "call:#{call.id}", %{
               "conversation_id" => account.conversation.id
             })

    hand_ref = push(socket, "call.hand.set.v1", %{"raised" => true})
    assert_reply(hand_ref, :ok, %{raised: true})
    assert_push("call.hand.v1", %{user_id: user_id, raised: true})
    assert user_id == account.user.id

    reaction_ref = push(socket, "call.reaction.v1", %{"emoji" => "👏"})
    assert_reply(reaction_ref, :ok)
    assert_push("call.reaction.v1", %{user_id: ^user_id, emoji: "👏"})

    invalid_ref = push(socket, "call.reaction.v1", %{"emoji" => "unsupported"})
    assert_reply(invalid_ref, :error, %{reason: "invalid_reaction"})
  end

  test "an established channel stops delivery after session revocation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:ok, ^call, _identity} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn request -> {:ok, request.provider_identity} end
             )

    socket = %Phoenix.Socket{
      topic: "call:#{call.id}",
      assigns:
        subject
        |> Map.put(:call_id, call.id)
        |> Map.put(:call_conversation_id, account.conversation.id)
    }

    account.session
    |> Session.changeset(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)})
    |> Repo.update!()

    assert {:stop, :unauthorized, ^socket} =
             CallChannel.handle_out("call.reaction.v1", %{}, socket)
  end

  test "two admitted direct-call participants exchange targeted bounded WebRTC signals" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {member, member_subject} = member_subject_fixture(account)

    assert {:ok, %{conversation: conversation}} =
             Conversations.get_or_create_direct_view(member.id, owner_subject)

    assert {:ok, call, :created} = AudioCalls.start(conversation.id, owner_subject)

    for subject <- [owner_subject, member_subject] do
      assert {:ok, admitted_call, _identity} =
               AudioCalls.with_join_authorized(
                 conversation.id,
                 call.id,
                 subject,
                 fn request -> {:ok, request.provider_identity} end
               )

      assert admitted_call.id == call.id
    end

    assert {:ok, %{direct_audio: owner_direct}, owner_socket} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "direct-owner", owner_subject),
               CallChannel,
               "call:#{call.id}",
               %{"conversation_id" => conversation.id, "direct_audio" => true}
             )

    assert owner_direct.enabled == true
    assert owner_direct.ice_servers == [%{urls: ["stun:stun.cloudflare.com:3478"]}]
    assert byte_size(owner_direct.peer_id) == 22

    assert {:ok, %{direct_audio: member_direct}, _member_socket} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "direct-member", member_subject),
               CallChannel,
               "call:#{call.id}",
               %{"conversation_id" => conversation.id, "direct_audio" => true}
             )

    assert member_direct.enabled == true
    assert member_direct.peer_id != owner_direct.peer_id

    assert_direct_peer_set([owner_direct.peer_id, member_direct.peer_id])

    signal_ref =
      push(owner_socket, "call.direct.signal.v1", %{
        "target_peer_id" => member_direct.peer_id,
        "signal" => %{"kind" => "offer", "sdp" => "v=0\r\n"}
      })

    assert_reply(signal_ref, :ok)

    assert_push("call.direct.signal.v1", %{
      from_peer_id: owner_peer_id,
      from_user_id: owner_user_id,
      target_peer_id: member_peer_id,
      signal: %{kind: "offer", sdp: "v=0\r\n"}
    })

    assert owner_peer_id == owner_direct.peer_id
    assert owner_user_id == account.user.id
    assert member_peer_id == member_direct.peer_id

    oversized_ref =
      push(owner_socket, "call.direct.signal.v1", %{
        "target_peer_id" => member_direct.peer_id,
        "signal" => %{"kind" => "offer", "sdp" => String.duplicate("x", 16_385)}
      })

    assert_reply(oversized_ref, :error, %{reason: "invalid_signal"})

    extra_field_ref =
      push(owner_socket, "call.direct.signal.v1", %{
        "target_peer_id" => member_direct.peer_id,
        "signal" => %{"kind" => "offer", "sdp" => "v=0\r\n", "private" => "not-allowed"}
      })

    assert_reply(extra_field_ref, :error, %{reason: "invalid_signal"})
  end

  test "direct signaling stays unavailable for a non-direct conversation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:ok, ^call, _identity} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn request -> {:ok, request.provider_identity} end
             )

    assert {:ok, %{direct_audio: %{enabled: false}}, socket} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "non-direct-owner", subject),
               CallChannel,
               "call:#{call.id}",
               %{"conversation_id" => account.conversation.id, "direct_audio" => true}
             )

    ref =
      push(socket, "call.direct.signal.v1", %{
        "target_peer_id" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "signal" => %{"kind" => "fallback"}
      })

    assert_reply(ref, :error, %{reason: "invalid_signal"})
  end

  defp member_subject_fixture(account) do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-member-password-#{suffix}"
    email = "call-member-#{suffix}@example.test"

    assert {:ok, member} =
             Accounts.create_user(
               %{
                 display_name: "Call Member #{suffix}",
                 email: email,
                 password: password,
                 role: "member"
               },
               Fixtures.step_up(account)
             )

    assert {:ok, login} =
             Accounts.authenticate_view(account.tenant.slug, email, password, %{
               name: "Call browser",
               platform: "test"
             })

    {:ok, access_context} = Accounts.access_context(login.session_id, "call-test")
    {member, access_context.subject}
  end

  defp restore_env(key, nil), do: Application.delete_env(:comms_web, key)
  defp restore_env(key, value), do: Application.put_env(:comms_web, key, value)

  defp assert_direct_peer_set(expected_peer_ids, attempts \\ 10)

  defp assert_direct_peer_set(_expected_peer_ids, 0),
    do: flunk("direct peer presence did not converge")

  defp assert_direct_peer_set(expected_peer_ids, attempts) do
    assert_push("call.direct.peers.v1", %{peers: peers})
    peer_ids = Enum.map(peers, & &1.peer_id)

    if Enum.all?(expected_peer_ids, &(&1 in peer_ids)) do
      :ok
    else
      assert_direct_peer_set(expected_peer_ids, attempts - 1)
    end
  end
end
