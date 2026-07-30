defmodule CommsWeb.ConversationChannel.PresenceTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias CommsCore.Conversations
  alias CommsCore.Conversations.EphemeralPresenceLease
  alias CommsCore.Repo
  alias CommsWeb.ConversationChannel
  alias CommsTestSupport.Fixtures

  @endpoint CommsWeb.Endpoint
  @moduletag :integration
  @moduletag :presence
  @moduletag :concurrency

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "an ephemeral channel opens, heartbeats, tracks, and closes durable presence" do
    account = Fixtures.account_fixture()
    configure_instant_rooms(account.tenant.slug)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{
                 display_name: "Realtime guest",
                 device: %{name: "Realtime browser", platform: "test"},
                 idempotency_key: base64url_secret(),
                 request_id: Ecto.UUID.generate()
               },
               :guest
             )

    authentication = created.authentication
    admission = created.admission

    subject = %{
      tenant_id: authentication.tenant.id,
      user_id: authentication.user.id,
      device_id: authentication.device.id,
      session_id: authentication.session_id,
      role: authentication.user.role,
      account_type: authentication.user.account_type,
      guest_conversation_id: created.conversation.id,
      guest_admission_id: admission.id,
      guest_history_from_sequence: admission.history_from_sequence,
      guest_expires_at: admission.expires_at
    }

    socket =
      CommsWeb.UserSocket
      |> socket("guest:#{authentication.user.id}", subject)

    assert {:ok, _reply, established_socket} =
             subscribe_and_join(
               socket,
               ConversationChannel,
               "conversation:#{created.conversation.id}",
               %{}
             )

    assert established_socket.assigns.ephemeral_room_id == created.room.id

    connection_id = established_socket.assigns.ephemeral_connection_id
    assert {:ok, connection_secret} = Base.url_decode64(connection_id, padding: false)
    assert byte_size(connection_secret) == 32
    assert Base.url_encode64(connection_secret, padding: false) == connection_id

    assert_push("presence_state", presence)
    assert %{metas: metas} = presence[authentication.user.id]

    assert Enum.any?(metas, fn meta ->
             meta.account_type == :guest and is_integer(meta.online_at)
           end)

    opened =
      Repo.get_by!(EphemeralPresenceLease,
        ephemeral_room_id: created.room.id,
        user_id: authentication.user.id,
        session_id: authentication.session_id
      )

    assert is_nil(opened.closed_at)

    send(established_socket.channel_pid, :ephemeral_presence_heartbeat)

    renewed =
      wait_for_lease(opened.id, fn lease ->
        lease.lock_version > opened.lock_version and is_nil(lease.closed_at)
      end)

    assert DateTime.compare(renewed.last_seen_at, opened.last_seen_at) in [:eq, :gt]

    Process.unlink(established_socket.channel_pid)
    leave_ref = leave(established_socket)
    assert_reply(leave_ref, :ok)

    closed = wait_for_lease(opened.id, &match?(%DateTime{}, &1.closed_at))
    assert DateTime.compare(closed.closed_at, renewed.last_seen_at) in [:eq, :gt]
  end

  test "presence deduplicates a user's tabs and removes the user only after the final tab leaves" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    topic = "conversation:#{account.conversation.id}"

    socket_one = socket(CommsWeb.UserSocket, "user:#{account.user.id}:one", subject)
    socket_two = socket(CommsWeb.UserSocket, "user:#{account.user.id}:two", subject)

    assert {:ok, _reply, tab_one} =
             subscribe_and_join(socket_one, ConversationChannel, topic, %{})

    assert {:ok, _reply, tab_two} =
             subscribe_and_join(socket_two, ConversationChannel, topic, %{})

    presence =
      wait_for_presence(topic, fn state ->
        match?(%{metas: [_, _]}, Map.get(state, account.user.id))
      end)

    assert Map.keys(presence) == [account.user.id]
    assert length(presence[account.user.id].metas) == 2

    Process.unlink(tab_one.channel_pid)
    assert_reply(leave(tab_one), :ok)

    presence =
      wait_for_presence(topic, fn state ->
        match?(%{metas: [_]}, Map.get(state, account.user.id))
      end)

    assert Map.keys(presence) == [account.user.id]

    Process.unlink(tab_two.channel_pid)
    assert_reply(leave(tab_two), :ok)

    assert %{} = wait_for_presence(topic, &(&1 == %{}))
  end

  defp configure_instant_rooms(tenant_slug) do
    settings = %{
      instant_rooms_enabled: true,
      instant_room_tenant_slug: tenant_slug,
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
  end

  defp base64url_secret do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp wait_for_lease(lease_id, predicate), do: wait_for_lease(lease_id, predicate, 50)

  defp wait_for_presence(topic, predicate), do: wait_for_presence(topic, predicate, 100)

  defp wait_for_presence(_topic, _predicate, 0),
    do: flunk("presence did not reach the expected state")

  defp wait_for_presence(topic, predicate, attempts_left) do
    presence = CommsWeb.Presence.list(topic)

    if predicate.(presence) do
      presence
    else
      Process.sleep(10)
      wait_for_presence(topic, predicate, attempts_left - 1)
    end
  end

  defp wait_for_lease(_lease_id, _predicate, 0),
    do: flunk("presence lease did not reach the expected state")

  defp wait_for_lease(lease_id, predicate, attempts_left) do
    lease = Repo.get!(EphemeralPresenceLease, lease_id)

    if predicate.(lease) do
      lease
    else
      Process.sleep(10)
      wait_for_lease(lease_id, predicate, attempts_left - 1)
    end
  end
end
