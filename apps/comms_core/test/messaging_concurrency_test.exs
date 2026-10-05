defmodule CommsCore.MessagingConcurrencyTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :messaging
  @moduletag :concurrency

  import Ecto.Query
  import CommsCore.MessagingFixtures

  alias CommsCore.{Audit, Messaging, Repo}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging.Message
  alias CommsTestSupport.Fixtures

  setup do
    # This fixture needs twelve simultaneous PostgreSQL backends plus the
    # observing test connection. No named Repo/sandbox/queue policy changes.
    options =
      Repo.config()
      |> Keyword.merge(name: nil, url: nil, pool: DBConnection.ConnectionPool, pool_size: 13)

    {:ok, repo} = Repo.start_link(options)
    Process.unlink(repo)
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    Repo.put_dynamic_repo(repo)

    suffix = Ecto.UUID.generate()
    slug = "messaging-concurrency-" <> suffix
    on_exit(fn -> with_repo(repo, fn -> cleanup(slug) end) end)

    account =
      Fixtures.account_fixture(%{
        tenant_slug: slug,
        email: "messaging-concurrency-#{suffix}@example.test"
      })

    {:ok, repo: repo, account: account}
  end

  test "concurrent retries return one canonical message and enqueue one outbox job", %{
    repo: repo,
    account: account
  } do
    subject = Fixtures.subject(account)

    attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: "concurrent-idempotency-message",
      body: "only once"
    }

    results =
      concurrent(repo, 12, fn _ -> Messaging.accept_message_with_status(attrs, subject) end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :duplicate}, &1)) == 11
    ids = Enum.map(results, fn {:ok, message, _status} -> message.id end)
    assert [canonical_id] = Enum.uniq(ids)

    assert Repo.aggregate(
             from(message in Message,
               where:
                 message.tenant_id == ^account.tenant.id and
                   message.sender_device_id == ^account.device.id and
                   message.client_message_id == ^attrs.client_message_id
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where:
                 event.tenant_id == ^account.tenant.id and event.aggregate_type == "message" and
                   event.aggregate_id == ^canonical_id and
                   event.event_type == "message.created.v1"
             ),
             :count
           ) == 1

    outbox =
      Repo.get_by!(OutboxEvent,
        tenant_id: account.tenant.id,
        aggregate_type: "message",
        aggregate_id: canonical_id,
        event_type: "message.created.v1"
      )

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.OutboxWorker" and
                   job.args == ^%{"event_id" => outbox.id, "tenant_id" => account.tenant.id}
             ),
             :count
           ) == 1

    assert Audit.count(%{tenant_id: account.tenant.id, action: "message.created"}) == 1
  end

  test "concurrent distinct messages receive contiguous owner-reserved sequences", %{
    repo: repo,
    account: account
  } do
    subject = Fixtures.subject(account)

    sequences =
      concurrent(repo, 8, fn index ->
        account
        |> message_attrs("owner-reserved-sequence-#{index}", [])
        |> Map.put(:body, "message #{index}")
        |> Messaging.accept_message(subject)
      end)
      |> Enum.map(fn {:ok, message} -> message.conversation_sequence end)
      |> Enum.sort()

    assert sequences == Enum.to_list(1..8)

    assert Repo.aggregate(
             from(message in Message,
               where: message.tenant_id == ^account.tenant.id
             ),
             :count
           ) == 8

    assert Audit.count(%{tenant_id: account.tenant.id, action: "message.created"}) == 8
  end

  defp concurrent(repo, attempts, operation) do
    parent = self()
    run = make_ref()

    tasks =
      for index <- 1..attempts do
        task =
          Task.async(fn ->
            with_repo(repo, fn ->
              Repo.checkout(fn ->
                [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
                send(parent, {:connected, run, self(), backend})

                receive do
                  {:run, ^run} -> operation.(index)
                after
                  5_000 -> raise "messaging concurrency start barrier timed out"
                end
              end)
            end)
          end)

        on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
        task
      end

    connections =
      for _ <- 1..attempts do
        assert_receive {:connected, ^run, pid, backend}, 5_000
        {pid, backend}
      end

    backends = Enum.map(connections, &elem(&1, 1))
    assert length(Enum.uniq(backends)) == attempts

    [[live_backends]] =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1::integer[]) AND backend_type = 'client backend'",
        [backends]
      ).rows

    assert live_backends == attempts

    for {pid, _backend} <- connections, do: send(pid, {:run, run})
    deadline = System.monotonic_time(:millisecond) + 15_000

    Enum.map(tasks, fn task ->
      Task.await(task, max(deadline - System.monotonic_time(:millisecond), 1))
    end)
  end

  defp cleanup(slug) do
    case Repo.get_by(Tenant, slug: slug) do
      nil ->
        :ok

      %Tenant{id: tenant_id} ->
        Repo.transaction(fn ->
          event_ids =
            Repo.all(
              from(event in OutboxEvent, where: event.tenant_id == ^tenant_id, select: event.id)
            )

          Repo.delete_all(
            from(job in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^tenant_id) or
                  fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids)
            )
          )

          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
        end)
    end
  end

  defp with_repo(repo, operation) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      operation.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
