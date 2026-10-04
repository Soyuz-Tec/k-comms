defmodule CommsWeb.ConversationChannel.RateLimitTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias CommsCore.Messaging.Message
  alias CommsCore.Repo
  alias CommsWeb.ConversationChannel
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL

  @moduletag :integration

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    CommsWeb.RateLimiter.reset()
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "ephemeral messages reject before domain work and reset at the minute boundary" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    window_start = 600_000_000

    install_database_clock(window_start + 59)

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

    refute Repo.exists?(
             from(message in Message,
               where: message.conversation_id == ^account.conversation.id
             )
           )

    set_database_clock(window_start + 60)

    assert :ok =
             CommsWeb.InstantRoomMessageRateLimit.consume(account.conversation.id, subject)

    assert [[1]] =
             SQL.query!(
               Repo,
               """
               SELECT request_count
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_message'
                 AND key_digest = $1
                 AND window_seconds = 60
                 AND window_started_at = timezone('UTC', to_timestamp($2::bigint))
               """,
               [message_digest, window_start + 60]
             ).rows
  end

  test "typing rejects before domain work and resets at its first-request window expiry" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    socket = %Phoenix.Socket{
      topic: "conversation:#{account.conversation.id}",
      assigns: Map.put(subject, :conversation_id, account.conversation.id)
    }

    typing_key = {
      :conversation_channel,
      :typing,
      subject.session_id,
      account.conversation.id
    }

    # Use the existing test clock to keep the exhausted fixture live for the
    # default test lifetime, then exercise its exact expiry without sleeping.
    started_at = System.monotonic_time(:second) + 60

    for _request <- 1..30 do
      assert CommsWeb.RateLimiter.allow_at?(typing_key, 30, 10, started_at)
    end

    assert {:reply, {:error, %{reason: "rate_limited"}}, ^socket} =
             ConversationChannel.handle_in("typing.start", %{}, socket)

    refute CommsWeb.RateLimiter.allow_at?(typing_key, 30, 10, started_at + 9)
    assert CommsWeb.RateLimiter.allow_at?(typing_key, 30, 10, started_at + 10)
  end

  defp install_database_clock(epoch_second) do
    # This connection's sandbox transaction owns the schema, function and
    # search_path override. Rollback removes them without a production hook.
    schema = "conversation_rate_clock_#{System.unique_integer([:positive, :monotonic])}"

    SQL.query!(Repo, "CREATE SCHEMA #{schema}", [])

    SQL.query!(
      Repo,
      """
      CREATE FUNCTION #{schema}.clock_timestamp() RETURNS timestamp with time zone
      LANGUAGE sql VOLATILE AS $$
        SELECT pg_catalog.to_timestamp(
          pg_catalog.current_setting('k_comms.test_rate_limit_epoch')::bigint
        )
      $$
      """,
      []
    )

    SQL.query!(Repo, "SET LOCAL search_path TO #{schema}, public, pg_catalog", [])
    set_database_clock(epoch_second)
  end

  defp set_database_clock(epoch_second) do
    SQL.query!(
      Repo,
      "SELECT pg_catalog.set_config('k_comms.test_rate_limit_epoch', $1, true)",
      [Integer.to_string(epoch_second)]
    )

    assert [[^epoch_second]] =
             SQL.query!(
               Repo,
               "SELECT floor(extract(epoch FROM clock_timestamp()))::bigint",
               []
             ).rows
  end
end
