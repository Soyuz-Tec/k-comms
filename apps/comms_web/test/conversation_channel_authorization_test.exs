defmodule CommsWeb.ConversationChannelAuthorizationTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias CommsCore.Accounts.Session
  alias CommsCore.Conversations.Conversation
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo
  alias CommsWeb.ConversationChannel
  alias CommsTestSupport.Fixtures

  @endpoint CommsWeb.Endpoint

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "commands and outbound events stop a channel after authorization is revoked" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    revoked_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    account.session
    |> Session.changeset(%{revoked_at: revoked_at})
    |> Repo.update!()

    socket =
      %Phoenix.Socket{
        topic: "conversation:#{account.conversation.id}",
        assigns: Map.put(subject, :conversation_id, account.conversation.id)
      }

    assert {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, ^socket} =
             ConversationChannel.handle_in(
               "message.send",
               %{"client_message_id" => "message-client-id", "body" => "blocked"},
               socket
             )

    assert {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, ^socket} =
             ConversationChannel.handle_in(
               "command",
               %{
                 "command_id" => "message-client-id",
                 "type" => "message.send.v1",
                 "payload" => %{"body" => "blocked"}
               },
               socket
             )

    assert {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, ^socket} =
             ConversationChannel.handle_in("conversation.read", %{"sequence" => 1}, socket)

    assert {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, ^socket} =
             ConversationChannel.handle_in(
               "command",
               %{
                 "command_id" => "read-command-id",
                 "type" => "conversation.read.v1",
                 "payload" => %{"sequence" => 1}
               },
               socket
             )

    assert {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, ^socket} =
             ConversationChannel.handle_in("typing.start", %{}, socket)

    for type <- ["typing.start.v1", "typing.stop.v1"] do
      assert {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, ^socket} =
               ConversationChannel.handle_in(
                 "command",
                 %{
                   "command_id" => "typing-command-id",
                   "type" => type,
                   "payload" => %{}
                 },
                 socket
               )
    end

    assert {:reply, {:error, %{reason: "invalid_command"}}, ^socket} =
             ConversationChannel.handle_in("command", %{"command_id" => "short"}, socket)

    assert {:reply, {:error, %{reason: "unsupported_command_type"}}, ^socket} =
             ConversationChannel.handle_in(
               "command",
               %{
                 "command_id" => "unknown-command-id",
                 "type" => "unknown.v1",
                 "payload" => %{}
               },
               socket
             )

    assert {:stop, :unauthorized, ^socket} =
             ConversationChannel.handle_out("message.created.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             ConversationChannel.handle_out("membership.changed.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             ConversationChannel.handle_out("conversation.updated.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             ConversationChannel.handle_out("conversation.archived.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             ConversationChannel.handle_out("presence_diff", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             ConversationChannel.handle_out("typing.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             ConversationChannel.handle_info(:after_join, socket)
  end

  test "join exposes replay pagination and command_id is the message idempotency key" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    messages =
      Enum.map(1..501, fn sequence ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: account.tenant.id,
          conversation_id: account.conversation.id,
          sender_user_id: account.user.id,
          sender_device_id: account.device.id,
          client_message_id: "replay-message-#{sequence}",
          conversation_sequence: sequence,
          body: "replay #{sequence}",
          metadata: %{},
          status: :active,
          inserted_at: now
        }
      end)

    assert {501, nil} = Repo.insert_all(Message, messages)

    account.conversation
    |> Conversation.changeset(%{next_sequence: 502})
    |> Repo.update!()

    socket =
      CommsWeb.UserSocket
      |> socket("user:#{account.user.id}", subject)

    assert {:ok, %{messages: replay, has_more: true, next_after_sequence: 500}, socket} =
             subscribe_and_join(
               socket,
               ConversationChannel,
               "conversation:#{account.conversation.id}",
               %{}
             )

    assert length(replay) == 500
    assert hd(replay).conversation_sequence == 1
    assert List.last(replay).conversation_sequence == 500

    command_id = "device-command-id-0001"

    ref =
      push(socket, "command", %{
        "command_id" => command_id,
        "type" => "message.send.v1",
        "payload" => %{
          "body" => "sent through the documented envelope",
          "client_message_id" => "untrusted-payload-value"
        }
      })

    assert_reply(ref, :ok, %{client_message_id: ^command_id})

    push(socket, "command", %{
      "command_id" => "typing-command-0001",
      "type" => "typing.start.v1",
      "payload" => %{}
    })

    assert_broadcast("typing.v1", %{user_id: user_id, state: "started"})
    assert user_id == account.user.id
  end

  test "an established channel stops authorizing after the stored absolute session deadline" do
    previous_ttl = Application.fetch_env!(:comms_core, :session_absolute_ttl_seconds)
    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 2)

    on_exit(fn ->
      Application.put_env(:comms_core, :session_absolute_ttl_seconds, previous_ttl)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    socket =
      CommsWeb.UserSocket
      |> socket("user:#{account.user.id}", subject)

    assert {:ok, _reply, established_socket} =
             subscribe_and_join(
               socket,
               ConversationChannel,
               "conversation:#{account.conversation.id}",
               %{}
             )

    Process.sleep(2_100)

    assert {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, ^established_socket} =
             ConversationChannel.handle_in("typing.start", %{}, established_socket)
  end
end
