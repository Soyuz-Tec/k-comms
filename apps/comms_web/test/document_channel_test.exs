defmodule CommsWeb.DocumentChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  alias CommsCore.{Accounts, Repo, SharedDocuments}
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
end
