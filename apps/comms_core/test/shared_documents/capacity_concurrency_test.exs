defmodule CommsCore.SharedDocuments.CapacityConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo, SharedDocuments}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Governance.TenantLock
  alias CommsCore.SharedDocuments.Document
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  test "the actual Governance tenant fence serializes separate-conversation creates at the last tenant slot" do
    {account, first_conversation, second_conversation} = fixture(true)
    parent = self()

    first =
      actor(parent, :first, fn ->
        Repo.transaction(fn ->
          # This is the real configured protection provider's lock, not a fake
          # adapter. It already excludes the old hypothetical cross-room race.
          TenantLock.lock!(account.tenant.id)
          send(parent, {:governance_retained, self()})

          receive do
            :continue -> create(first_conversation.id, account)
          after
            10_000 -> raise "document capacity Governance barrier timed out"
          end
        end)
      end)

    assert_receive {:first_backend, first_backend}, 5_000
    assert_receive {:governance_retained, first_pid}, 5_000
    second = actor(parent, :second, fn -> create(second_conversation.id, account) end)
    assert_receive {:second_backend, second_backend}, 5_000
    {query, blockers} = wait_for_lock(second_backend)
    assert String.contains?(query, "pg_advisory_xact_lock(hashtextextended($1, 0))")
    assert first_backend in blockers
    send(first_pid, :continue)
    assert {:ok, {:ok, document}} = Task.await(first, 10_000)
    assert document.conversation_id == first_conversation.id
    assert {:error, :document_capacity_exceeded} = Task.await(second, 10_000)

    unboxed(fn ->
      assert Repo.aggregate(
               from(document in Document, where: document.tenant_id == ^account.tenant.id),
               :count
             ) == 1_000

      assert Repo.aggregate(
               from(document in Document,
                 where: document.conversation_id == ^second_conversation.id
               ),
               :count
             ) == 0
    end)
  end

  test "copy takes the owner capacity prefix before retaining its source document" do
    {account, _, _} = fixture(false)
    {:ok, source} = unboxed(fn -> create(account.conversation.id, account) end)
    parent = self()

    holder =
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [
            "shared-document-tenant-capacity:#{account.tenant.id}"
          ])

          send(parent, {:capacity_retained, self()})

          receive do
            :check_source ->
              Repo.query!("SET LOCAL lock_timeout = '1000ms'", [])

              Repo.one!(
                from(document in Document, where: document.id == ^source.id, lock: "FOR UPDATE")
              )

              send(parent, :source_available_before_capacity_release)
              :ok
          after
            10_000 -> raise "document owner capacity barrier timed out"
          end
        end)
      end)

    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive {:capacity_retained, holder_pid}, 5_000

    copier =
      actor(parent, :copier, fn ->
        SharedDocuments.copy(
          source.id,
          %{client_document_id: Ecto.UUID.generate(), title: "Prefix copy"},
          Fixtures.subject(account)
        )
      end)

    assert_receive {:copier_backend, copier_backend}, 5_000
    {query, blockers} = wait_for_lock(copier_backend)
    assert String.contains?(query, "pg_advisory_xact_lock(hashtextextended($1::text, 0))")
    assert holder_backend in blockers
    send(holder_pid, :check_source)
    assert_receive :source_available_before_capacity_release, 5_000
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:ok, copied} = Task.await(copier, 10_000)
    assert copied.content == source.content
  end

  test "simultaneous stale device edits produce ordered convergent receipts without losing either intent" do
    {account, _, _} = fixture(false)
    {:ok, document} = unboxed(fn -> create(account.conversation.id, account) end)

    other =
      unboxed(fn ->
        suffix = account.tenant.slug |> String.split("-") |> List.last()

        {:ok, authentication} =
          Accounts.authenticate_view(
            account.tenant.slug,
            account.user.email,
            "correct-horse-battery-#{suffix}",
            %{name: "Concurrent document device", platform: "test"}
          )

        %{
          Fixtures.subject(account)
          | session_id: authentication.session_id,
            device_id: authentication.device.id
        }
      end)

    first_input = edit("A")
    second_input = edit("B")
    parent = self()

    first =
      actor(parent, :first, fn ->
        Repo.transaction(fn ->
          TenantLock.lock!(account.tenant.id)
          send(parent, {:writer_retained, self()})

          receive do
            :continue ->
              SharedDocuments.apply_operation(document.id, first_input, Fixtures.subject(account))
          after
            10_000 -> raise "document simultaneous-edit barrier timed out"
          end
        end)
      end)

    assert_receive {:first_backend, first_backend}, 5_000
    assert_receive {:writer_retained, first_pid}, 5_000

    second =
      actor(parent, :second, fn ->
        SharedDocuments.apply_operation(document.id, second_input, other)
      end)

    assert_receive {:second_backend, second_backend}, 5_000
    {_query, blockers} = wait_for_lock(second_backend)
    assert first_backend in blockers
    send(first_pid, :continue)
    assert {:ok, {:ok, first_receipt, :created}} = Task.await(first, 10_000)
    assert {:ok, second_receipt, :created} = Task.await(second, 10_000)
    assert first_receipt.version == 2 and second_receipt.version == 3

    unboxed(fn ->
      assert {:ok, %{content: "BA", version: 3}} =
               SharedDocuments.get(document.id, Fixtures.subject(account))

      assert {:ok, %{operations: [^first_receipt, ^second_receipt], has_more: false}} =
               SharedDocuments.replay(document.id, 1, 1, 100, other)

      assert {:ok, ^first_receipt, :duplicate} =
               SharedDocuments.apply_operation(
                 document.id,
                 first_input,
                 Fixtures.subject(account)
               )

      assert {:ok, %{content: "BA", version: 3}} = SharedDocuments.get(document.id, other)
    end)
  end

  defp edit(text),
    do: %{
      client_operation_id: Ecto.UUID.generate(),
      generation: 1,
      base_version: 1,
      kind: "edit",
      changes: [%{"after_id" => nil, "delete_ids" => [], "insert" => text}]
    }

  defp fixture(seed_capacity) do
    {account, first, second} =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        first = conversation(account, "First capacity contender")
        second = conversation(account, "Second capacity contender")

        if seed_capacity do
          timestamp = DateTime.utc_now()
          # Seed valid bounded retained rows over 25 conversations; neither
          # contender hits its independent 40-document conversation limit.
          for index <- 0..24 do
            room = conversation(account, "Retained capacity seed #{index}")
            count = if index == 24, do: 39, else: 40

            rows =
              for _ <- 1..count do
                %{
                  id: Ecto.UUID.generate(),
                  tenant_id: account.tenant.id,
                  conversation_id: room.id,
                  client_document_id: Ecto.UUID.generate(),
                  created_by_user_id: account.user.id,
                  created_by_device_id: account.device.id,
                  title: "Retained synthetic capacity",
                  content: "",
                  atoms: [],
                  author_user_ids: [account.user.id],
                  lineage_verified: true,
                  generation: 1,
                  version: 1,
                  retained_operation_bytes: 0,
                  inserted_at: timestamp,
                  updated_at: timestamp
                }
              end

            {^count, _} = Repo.insert_all(Document, rows)
          end
        end

        {account, first, second}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          # Unboxed fixtures are synthetic and isolated to this test tenant.
          Repo.query!("DELETE FROM shared_document_operations WHERE tenant_id = $1", [
            Ecto.UUID.dump!(account.tenant.id)
          ])

          Repo.delete_all(
            from(document in Document, where: document.tenant_id == ^account.tenant.id)
          )

          event_ids =
            Repo.all(
              from(event in OutboxEvent,
                where: event.tenant_id == ^account.tenant.id,
                select: event.id
              )
            )

          Repo.delete_all(
            from(job in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id) or
                  fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids)
            )
          )

          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
        end)
      end)
    end)

    {account, first, second}
  end

  defp conversation(account, title) do
    {:ok, conversation} =
      Conversations.create_view(%{kind: "channel", title: title}, Fixtures.subject(account))

    conversation
  end

  defp create(conversation_id, account),
    do:
      SharedDocuments.create(
        conversation_id,
        %{client_document_id: Ecto.UUID.generate(), title: "Capacity contender"},
        Fixtures.subject(account)
      )

  defp actor(parent, label, operation) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp wait_for_lock(backend, attempts \\ 300)

  defp wait_for_lock(_, 0),
    do: flunk("document contender did not reach an actual database lock wait")

  defp wait_for_lock(backend, attempts) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
             [backend]
           ).rows
         end) do
      [[query, blockers]] ->
        {query, blockers}

      [] ->
        Process.sleep(10)
        wait_for_lock(backend, attempts - 1)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
