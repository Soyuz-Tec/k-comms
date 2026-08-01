defmodule CommsWeb.WhiteboardChannelTest do
  use ExUnit.Case, async: false

  @moduletag :whiteboard
  @moduletag :integration

  import Phoenix.ChannelTest

  alias CommsCore.Accounts.Session
  alias CommsCore.Repo
  alias CommsWeb.WhiteboardChannel
  alias CommsTestSupport.Fixtures

  @endpoint CommsWeb.Endpoint

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "members join and exchange bounded ephemeral presence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    topic = "whiteboard:#{account.conversation.id}"

    socket_one = socket(CommsWeb.UserSocket, "whiteboard-one", subject)
    socket_two = socket(CommsWeb.UserSocket, "whiteboard-two", subject)

    assert {:ok, %{}, socket_one} =
             subscribe_and_join(socket_one, WhiteboardChannel, topic, %{"protocol_version" => 1})

    assert {:ok, %{}, _socket_two} =
             subscribe_and_join(socket_two, WhiteboardChannel, topic, %{"protocol_version" => 1})

    push(socket_one, "whiteboard.presence.v1", %{
      "pointer" => %{"x" => 10.5, "y" => 20, "tool" => "pointer"},
      "button" => "down",
      "selected_element_ids" => ["element-one"]
    })

    assert_push("whiteboard.presence.v1", %{
      user_id: user_id,
      device_id: device_id,
      pointer: %{"x" => 10.5, "y" => 20, "tool" => "pointer"},
      button: true,
      selected_element_ids: ["element-one"]
    })

    assert user_id == account.user.id
    assert device_id == account.device.id

    push(socket_one, "whiteboard.presence.v1", %{
      "pointer" => %{"x" => 2_000_000, "y" => 20, "tool" => "untrusted"},
      "selected_element_ids" => []
    })

    refute_push("whiteboard.presence.v1", _payload, 50)
  end

  test "non-members cannot join" do
    account = Fixtures.account_fixture()
    outsider = Fixtures.account_fixture()

    socket =
      socket(
        CommsWeb.UserSocket,
        "whiteboard-outsider",
        Fixtures.subject(outsider)
      )

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(
               socket,
               WhiteboardChannel,
               "whiteboard:#{account.conversation.id}",
               %{}
             )
  end

  test "established channels stop delivering operations and presence after revocation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    socket = %Phoenix.Socket{
      topic: "whiteboard:#{account.conversation.id}",
      assigns: Map.put(subject, :whiteboard_conversation_id, account.conversation.id)
    }

    account.session
    |> Session.changeset(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)})
    |> Repo.update!()

    assert {:stop, :unauthorized, ^socket} =
             WhiteboardChannel.handle_out("whiteboard.operation_applied.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             WhiteboardChannel.handle_out("whiteboard.presence.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             WhiteboardChannel.handle_in(
               "whiteboard.presence.v1",
               %{"pointer" => %{"x" => 0, "y" => 0}},
               socket
             )
  end
end
