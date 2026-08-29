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
  @audio_sdp "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-ufrag:abcd\r\na=ice-pwd:abcdefghijklmnopqrstuv\r\na=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00\r\na=setup:actpass\r\na=rtcp-mux\r\n"

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

    assert {:ok, %{direct_audio: member_direct}, member_socket} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "direct-member", member_subject),
               CallChannel,
               "call:#{call.id}",
               %{"conversation_id" => conversation.id, "direct_audio" => true}
             )

    assert member_direct.enabled == true
    assert member_direct.peer_id != owner_direct.peer_id

    assert_direct_peer_set([owner_direct.peer_id, member_direct.peer_id])

    {offer_socket, answer_socket, offer_direct, answer_direct, offer_user_id} =
      if owner_direct.peer_id < member_direct.peer_id do
        {owner_socket, member_socket, owner_direct, member_direct, account.user.id}
      else
        {member_socket, owner_socket, member_direct, owner_direct, member.id}
      end

    wrong_offerer_ref =
      push(answer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => offer_direct.peer_id,
        "signal" => %{"kind" => "offer", "sdp" => @audio_sdp}
      })

    assert_reply(wrong_offerer_ref, :error, %{reason: "invalid_signal"})

    video_ref =
      push(offer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => answer_direct.peer_id,
        "signal" => %{
          "kind" => "offer",
          "sdp" => "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
        }
      })

    assert_reply(video_ref, :error, %{reason: "invalid_signal"})

    oversized_ref =
      push(offer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => answer_direct.peer_id,
        "signal" => %{"kind" => "offer", "sdp" => String.duplicate("x", 16_385)}
      })

    assert_reply(oversized_ref, :error, %{reason: "invalid_signal"})

    extra_field_ref =
      push(offer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => answer_direct.peer_id,
        "signal" => %{"kind" => "offer", "sdp" => @audio_sdp, "private" => "not-allowed"}
      })

    assert_reply(extra_field_ref, :error, %{reason: "invalid_signal"})

    signal_ref =
      push(offer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => answer_direct.peer_id,
        "signal" => %{"kind" => "offer", "sdp" => @audio_sdp}
      })

    assert_reply(signal_ref, :ok)

    assert_push("call.direct.signal.v1", %{
      from_peer_id: owner_peer_id,
      from_user_id: ^offer_user_id,
      target_peer_id: answer_peer_id,
      signal: %{kind: "offer", sdp: @audio_sdp}
    })

    assert owner_peer_id == offer_direct.peer_id
    assert answer_peer_id == answer_direct.peer_id

    answer_ref =
      push(answer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => offer_direct.peer_id,
        "signal" => %{"kind" => "answer", "sdp" => @audio_sdp}
      })

    assert_reply(answer_ref, :ok)
    assert_push("call.direct.signal.v1", %{signal: %{kind: "answer", sdp: @audio_sdp}})

    fallback_ref =
      push(answer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => offer_direct.peer_id,
        "signal" => %{"kind" => "fallback"}
      })

    assert_reply(fallback_ref, :ok)
    assert_push("call.direct.disabled.v1", %{reason: "peer_fallback"})
    assert_push("call.direct.signal.v1", %{signal: %{kind: "fallback"}})

    after_fallback_ref =
      push(answer_socket, "call.direct.signal.v1", %{
        "target_peer_id" => offer_direct.peer_id,
        "signal" => %{"kind" => "fallback"}
      })

    assert_reply(after_fallback_ref, :error, %{reason: "invalid_signal"})
  end

  test "a second direct session for the same user is disabled and cannot expand presence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {member, _member_subject} = member_subject_fixture(account)

    assert {:ok, %{conversation: conversation}} =
             Conversations.get_or_create_direct_view(member.id, subject)

    assert {:ok, call, :created} = AudioCalls.start(conversation.id, subject)

    assert {:ok, ^call, _identity} =
             AudioCalls.with_join_authorized(
               conversation.id,
               call.id,
               subject,
               fn request -> {:ok, request.provider_identity} end
             )

    assert {:ok, %{direct_audio: first_direct}, _first_socket} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "direct-primary", subject),
               CallChannel,
               "call:#{call.id}",
               %{"conversation_id" => conversation.id, "direct_audio" => true}
             )

    assert first_direct.enabled == true
    assert_direct_peer_set([first_direct.peer_id])

    assert {:ok, %{direct_audio: %{enabled: false}}, second_socket} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "direct-duplicate", subject),
               CallChannel,
               "call:#{call.id}",
               %{"conversation_id" => conversation.id, "direct_audio" => true}
             )

    ref =
      push(second_socket, "call.direct.signal.v1", %{
        "target_peer_id" => first_direct.peer_id,
        "signal" => %{"kind" => "fallback"}
      })

    assert_reply(ref, :error, %{reason: "invalid_signal"})
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

    outcome_ref =
      push(socket, "call.direct.outcome.v1", %{"result" => "fallback", "reason" => "ice_timeout"})

    assert_reply(outcome_ref, :error, %{reason: "direct_audio_unavailable"})
  end

  test "an admitted direct participant reports one bounded transport outcome" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {member, _member_subject} = member_subject_fixture(account)

    assert {:ok, %{conversation: conversation}} =
             Conversations.get_or_create_direct_view(member.id, owner_subject)

    assert {:ok, call, :created} = AudioCalls.start(conversation.id, owner_subject)

    assert {:ok, _admitted_call, _identity} =
             AudioCalls.with_join_authorized(
               conversation.id,
               call.id,
               owner_subject,
               fn request -> {:ok, request.provider_identity} end
             )

    reset_peer_link_metrics()

    assert {:ok, %{direct_audio: %{enabled: true}}, socket} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "outcome-owner", owner_subject),
               CallChannel,
               "call:#{call.id}",
               %{"conversation_id" => conversation.id, "direct_audio" => true}
             )

    assert peer_link_metric("k_comms_peer_link_attempts_total") == 1

    invalid_ref =
      push(socket, "call.direct.outcome.v1", %{
        "result" => "connected",
        "candidate_class" => "tcp",
        "connect_ms" => 10
      })

    assert_reply(invalid_ref, :error, %{reason: "invalid_outcome"})

    identifier_ref =
      push(socket, "call.direct.outcome.v1", %{
        "result" => "fallback",
        "reason" => "signaling",
        "peer_address" => "203.0.113.9"
      })

    assert_reply(identifier_ref, :error, %{reason: "invalid_outcome"})

    outcome_ref =
      push(socket, "call.direct.outcome.v1", %{
        "result" => "connected",
        "candidate_class" => "relay",
        "connect_ms" => 1_400
      })

    assert_reply(outcome_ref, :ok)

    repeat_ref =
      push(socket, "call.direct.outcome.v1", %{"result" => "fallback", "reason" => "ice_timeout"})

    assert_reply(repeat_ref, :ok)

    assert peer_link_metric("k_comms_peer_link_connections_total{candidate_class=\"relay\"}") == 1
    assert peer_link_metric("k_comms_peer_link_fallbacks_total{reason=\"ice_timeout\"}") == 0
  end

  defp reset_peer_link_metrics do
    if :ets.whereis(CommsObservability.Metrics) != :undefined do
      :ets.delete_all_objects(CommsObservability.Metrics)
    end

    :ok
  end

  defp peer_link_metric(series) do
    CommsObservability.Metrics.render()
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, " ", parts: 2) do
        [^series, value] -> String.to_integer(value)
        _ -> nil
      end
    end)
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
