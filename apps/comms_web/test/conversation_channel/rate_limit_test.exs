defmodule CommsWeb.ConversationChannel.RateLimitTest do
  use ExUnit.Case, async: false

  alias CommsCore.Repo
  alias CommsWeb.ConversationChannel
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    CommsWeb.RateLimiter.reset()
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "ephemeral message and typing limits reject before domain work" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    socket =
      %Phoenix.Socket{
        topic: "conversation:#{account.conversation.id}",
        assigns:
          subject
          |> Map.put(:conversation_id, account.conversation.id)
          |> Map.put(:ephemeral_room_id, Ecto.UUID.generate())
      }

    message_digest =
      CommsWeb.Plugs.DistributedRateLimit.key_digest(:instant_room_message, [
        "identity-room",
        0,
        subject.tenant_id,
        0,
        subject.user_id,
        0,
        subject.session_id,
        0,
        account.conversation.id
      ])

    for _request <- 1..30 do
      assert %{allowed: true} =
               CommsCore.PlatformRateLimits.allow?(
                 :instant_room_message,
                 message_digest,
                 30,
                 60
               )
    end

    assert {:reply, {:error, %{reason: "rate_limited"}}, ^socket} =
             ConversationChannel.handle_in(
               "message.send",
               %{"client_message_id" => "rate-limited-message", "body" => "blocked"},
               socket
             )

    typing_key = {
      :conversation_channel,
      :typing,
      subject.session_id,
      account.conversation.id
    }

    for _request <- 1..30 do
      assert CommsWeb.RateLimiter.allow?(typing_key, 30, 10)
    end

    assert {:reply, {:error, %{reason: "rate_limited"}}, ^socket} =
             ConversationChannel.handle_in("typing.start", %{}, socket)
  end
end
