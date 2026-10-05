defmodule CommsCore.GovernanceDeleteCompletionLockOrderTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Conversations, Governance, Messaging, Repo, RuntimePorts}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Messaging.{Message, MessageRevision}
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @moduletag :governance

  # Actual public operations compete for the Governance tenant fence.
  for first <- [:complete, :delete] do
    @first first

    @tag timeout: 30_000
    test "real #{@first} first serializes delete/completion before Message authority" do
      fixture = fixture()
      parent = self()
      second_operation = if @first == :complete, do: :delete, else: :complete

      first = actor(parent, :first, fn -> invoke(@first, fixture) end, barrier: true)
      assert_receive {:first_backend, first_backend}, 5_000
      assert_receive {:first_tenant_retained, first_pid, release}, 5_000

      second = actor(parent, :second, fn -> invoke(second_operation, fixture) end, trace: true)
      assert_receive {:second_backend, second_backend}, 5_000
      {query, blockers} = wait_for_lock(second_backend)
      assert String.contains?(query, "pg_advisory_xact_lock")
      assert first_backend in blockers

      # In the old completion-first order, the deleter already retained Message
      # UPDATE when it waited at this tenant policy fence. Releasing completion
      # would then form Tenant→Message / Message→Tenant. Prove the corrected
      # public prefix has no retained Message or actor User before its wait.
      trace = query_trace()

      refute Enum.any?(trace, fn query ->
               String.contains?(query, ~s(FROM "messages")) and
                 String.contains?(query, "FOR UPDATE")
             end)

      refute Enum.any?(trace, fn query ->
               String.contains?(query, ~s(FROM "users")) and
                 (String.contains?(query, "FOR SHARE") or
                    String.contains?(query, "FOR NO KEY UPDATE"))
             end)

      send(first_pid, {:release_tenant, release})
      assert_success(@first, Task.await(first, 10_000))
      assert_success(second_operation, Task.await(second, 10_000))

      unboxed(fn ->
        assert Repo.get!(DeletionRequest, fixture.claim.request_id).status == :completed
        message = Repo.get!(Message, fixture.message.id)
        assert message.status == :deleted
        assert is_nil(message.body)
        assert message.metadata == %{}

        refute Repo.exists?(
                 from(revision in MessageRevision,
                   where: revision.message_id == ^message.id
                 )
               )

        events =
          Repo.all(
            from(event in OutboxEvent,
              where:
                event.tenant_id == ^fixture.account.tenant.id and
                  event.aggregate_id == ^message.id
            )
          )

        assert length(events) == 3

        if @first == :delete do
          assert Enum.all?(events, &(&1.payload == %{"content_erased" => true}))
        else
          # A later ordinary deletion may append its existing body-free delete
          # event, while earlier create/edit copies remain erased.
          assert Enum.count(events, &(&1.payload == %{"content_erased" => true})) == 2
          refute Enum.any?(events, &Map.has_key?(&1.payload, "body"))
        end
      end)
    end
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        subject = Fixtures.step_up(account)

        assert {:ok, conversation} =
                 Conversations.create(
                   %{title: "Actual delete/completion ordering", kind: "group", member_ids: []},
                   subject
                 )

        assert {:ok, message} =
                 Messaging.accept_message(
                   %{
                     tenant_id: account.tenant.id,
                     conversation_id: conversation.id,
                     sender_user_id: account.user.id,
                     sender_device_id: account.device.id,
                     client_message_id: "delete-completion-lock-" <> account.user.id,
                     body: "Private original retained only until verified erasure"
                   },
                   subject
                 )

        assert {:ok, edited} = Messaging.edit_message(message.id, "Private replacement", subject)

        assert {:ok, %{request: request}} =
                 Governance.create_deletion_request(
                   %{
                     target_type: "message",
                     message_id: message.id,
                     reason: "Verify public deletion and completion ordering"
                   },
                   subject
                 )

        assert {:ok, _approved} =
                 Governance.transition_deletion_request(
                   request.id,
                   %{
                     version: request.lock_version,
                     status: "approved",
                     transition_reason: "Verified"
                   },
                   subject
                 )

        assert {:ok, claim} =
                 Governance.claim_deletion_request(
                   request.id,
                   RuntimePorts.job_worker!(:deletion)
                 )

        %{account: account, subject: subject, message: edited, claim: claim}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          tenant_id = fixture.account.tenant.id

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
      end)
    end)

    fixture
  end

  defp invoke(:complete, fixture),
    do:
      Governance.complete_deletion_request(
        fixture.claim.request_id,
        fixture.claim.expected_version,
        %{deleted_object_count: 0},
        RuntimePorts.job_worker!(:deletion)
      )

  defp invoke(:delete, fixture),
    do: Governance.delete_message(fixture.message.id, fixture.subject)

  defp assert_success(:complete, result),
    do: assert(match?({:ok, %{request: %{status: :completed}}}, result))

  defp assert_success(:delete, result), do: assert(match?({:ok, %{status: :deleted}}, result))

  defp actor(parent, label, operation, opts) do
    trace_handler = {__MODULE__, :trace, make_ref()}
    on_exit(fn -> :telemetry.detach(trace_handler) end)

    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          if Keyword.get(opts, :barrier), do: tenant_barrier(parent, label)
          if Keyword.get(opts, :trace), do: attach_trace(parent, trace_handler)
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp tenant_barrier(parent, label) do
    handler = {__MODULE__, :tenant, make_ref()}
    release = make_ref()
    actor = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == actor and String.contains?(metadata.query, "pg_advisory_xact_lock") do
            :telemetry.detach(handler)
            send(parent, {String.to_atom("#{label}_tenant_retained"), actor, release})

            receive do
              {:release_tenant, ^release} -> :ok
            after
              12_000 -> raise "delete/completion tenant barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp attach_trace(parent, handler) do
    actor = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == actor, do: send(parent, {:owner_query, metadata.query})
        end,
        nil
      )
  end

  defp query_trace(result \\ []) do
    receive do
      {:owner_query, query} -> query_trace([query | result])
    after
      0 -> Enum.reverse(result)
    end
  end

  defp wait_for_lock(backend, attempts \\ 300)
  defp wait_for_lock(_backend, 0), do: flunk("owner did not reach actual Governance tenant wait")

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
