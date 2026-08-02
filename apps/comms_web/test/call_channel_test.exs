defmodule CommsWeb.CallChannelTest do
  use ExUnit.Case, async: false

  @moduletag :call
  @moduletag :integration

  import Phoenix.ChannelTest

  alias CommsCore.Accounts.Session
  alias CommsCore.{AudioCalls, Repo}
  alias CommsTestSupport.Fixtures
  alias CommsWeb.CallChannel

  @endpoint CommsWeb.Endpoint

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
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
end
