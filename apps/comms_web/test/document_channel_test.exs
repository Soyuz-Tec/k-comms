defmodule CommsWeb.DocumentChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  alias CommsCore.{Accounts, Conversations, Repo, SharedDocuments}
  alias CommsWeb.DocumentChannel
  alias CommsTestSupport.Fixtures
  @endpoint CommsWeb.Endpoint
  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    {:ok, document} =
      SharedDocuments.create(
        account.conversation.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Channel notes"},
        subject
      )

    %{account: account, subject: subject, document: document}
  end

  test "only current members join and exchange bounded document selections", context do
    topic = "document:" <> context.document.id
    one = socket(CommsWeb.UserSocket, "document-one", context.subject)
    two = socket(CommsWeb.UserSocket, "document-two", context.subject)
    assert {:ok, %{}, one} = subscribe_and_join(one, DocumentChannel, topic, %{})
    assert {:ok, %{}, _two} = subscribe_and_join(two, DocumentChannel, topic, %{})
    push(one, "document.presence.v1", %{"generation" => 1, "anchor_id" => nil, "head_id" => nil})

    assert_push("document.presence.v1", %{
      generation: 1,
      anchor_id: nil,
      head_id: nil,
      user_id: user_id
    })

    assert user_id == context.account.user.id

    push(one, "document.presence.v1", %{
      "generation" => 1,
      "anchor_id" => Ecto.UUID.generate() <> ":0",
      "head_id" => nil
    })

    refute_push("document.presence.v1", _, 50)
    foreign = Fixtures.account_fixture() |> Fixtures.subject()

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "document-foreign", foreign),
               DocumentChannel,
               topic,
               %{}
             )
  end

  test "established sockets cannot receive operations or send selections after session revocation",
       context do
    socket = %Phoenix.Socket{
      topic: "document:" <> context.document.id,
      assigns: Map.put(context.subject, :shared_document_id, context.document.id)
    }

    assert :ok = Accounts.revoke_session(context.account.session.id, context.account.user.id)

    assert {:stop, :unauthorized, ^socket} =
             DocumentChannel.handle_out("document.operation_applied.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             DocumentChannel.handle_out("document.presence.v1", %{}, socket)

    assert {:stop, :unauthorized, ^socket} =
             DocumentChannel.handle_in(
               "document.presence.v1",
               %{"generation" => 1, "anchor_id" => nil, "head_id" => nil},
               socket
             )
  end

  for event <- ["document.operation_applied.v1", "document.presence.v1"] do
    test "a subscribed member receives no #{event} after public membership removal", context do
      event = unquote(event)
      {member, membership} = join_member(context)
      topic = "document:" <> context.document.id

      assert {:ok, %{}, joined} =
               subscribe_and_join(
                 socket(CommsWeb.UserSocket, "withdrawn-#{event}", member),
                 DocumentChannel,
                 topic,
                 %{}
               )

      Process.unlink(joined.channel_pid)
      monitor = Process.monitor(joined.channel_pid)
      payload = authorized_payload(event, context)
      :ok = CommsWeb.Endpoint.broadcast(topic, event, payload)
      assert_push(^event, ^payload)
      remove_member(context, member, membership)
      :ok = CommsWeb.Endpoint.broadcast(topic, event, payload)
      assert_receive {:DOWN, ^monitor, :process, _, :unauthorized}
      refute_push(^event, _, 50)

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(
                 socket(CommsWeb.UserSocket, "withdrawn-rejoin", member),
                 DocumentChannel,
                 topic,
                 %{}
               )
    end
  end

  test "an established member cannot send document selections after public membership removal",
       context do
    {member, membership} = join_member(context)
    topic = "document:" <> context.document.id

    assert {:ok, %{}, joined} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "withdrawn-input", member),
               DocumentChannel,
               topic,
               %{}
             )

    assert {:ok, %{}, _peer} =
             subscribe_and_join(
               socket(CommsWeb.UserSocket, "remaining-peer", context.subject),
               DocumentChannel,
               topic,
               %{}
             )

    Process.unlink(joined.channel_pid)
    monitor = Process.monitor(joined.channel_pid)
    selection = %{"generation" => 1, "anchor_id" => nil, "head_id" => nil}
    push(joined, "document.presence.v1", selection)
    assert_push("document.presence.v1", %{user_id: user_id})
    assert user_id == member.user_id
    remove_member(context, member, membership)
    push(joined, "document.presence.v1", selection)
    assert_receive {:DOWN, ^monitor, :process, _, :unauthorized}
    refute_push("document.presence.v1", _, 50)
  end

  defp join_member(context) do
    %{user: user} = Fixtures.user_fixture(context.account)
    suffix = user.email |> String.split(["member-", "@example.test"]) |> Enum.at(1)

    {:ok, authentication} =
      Accounts.authenticate_view(
        context.account.tenant.slug,
        user.email,
        "correct-horse-battery-#{suffix}",
        %{
          name: "Subscribed document member",
          platform: "test"
        }
      )

    {:ok, membership} =
      Conversations.add_member_view(
        context.account.conversation.id,
        user.id,
        :member,
        context.subject
      )

    subject = %{
      tenant_id: context.account.tenant.id,
      user_id: user.id,
      session_id: authentication.session_id,
      device_id: authentication.device.id,
      role: :member
    }

    {subject, membership}
  end

  defp remove_member(context, member, membership) do
    assert {:ok, %{left_at: %DateTime{}}} =
             Conversations.remove_member_view(
               context.account.conversation.id,
               member.user_id,
               %{version: membership.version},
               context.subject
             )
  end

  defp authorized_payload("document.presence.v1", context) do
    %{
      user_id: context.account.user.id,
      device_id: context.account.device.id,
      generation: context.document.generation,
      anchor_id: nil,
      head_id: nil
    }
  end

  defp authorized_payload("document.operation_applied.v1", context) do
    assert {:ok, operation, :created} =
             SharedDocuments.apply_operation(
               context.document.id,
               %{
                 client_operation_id: Ecto.UUID.generate(),
                 generation: context.document.generation,
                 base_version: context.document.version,
                 kind: "edit",
                 changes: [
                   %{"after_id" => nil, "delete_ids" => [], "insert" => "Committed operation"}
                 ]
               },
               context.subject
             )

    Map.from_struct(operation)
  end
end
