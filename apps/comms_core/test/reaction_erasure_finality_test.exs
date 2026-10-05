defmodule CommsCore.ReactionErasureFinalityTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias CommsCore.{Accounts, Conversations, Governance, Messaging, Repo, RuntimePorts}
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging.Reaction
  alias CommsTestSupport.Fixtures
  @query_event [:comms_core, :repo, :query]
  @password "synthetic-reaction-finality-target-password"
  @moduletag :integration
  @moduletag :concurrency
  @moduletag :governance

  @tag timeout: 30_000
  test "real governed parent UPDATE rejects the former reaction FK-wait after tombstone" do
    c = fixture()
    parent = self()

    predicate = fn query ->
      String.contains?(query, ~s(FROM "messages")) and
        String.contains?(query, "FOR UPDATE")
    end

    eraser = actor(parent, :eraser, fn -> complete(c.claim) end, predicate)
    assert_receive {:eraser_backend, eraser_backend}, 5_000
    assert_receive {:eraser_barrier, eraser_pid, release}, 5_000

    writer =
      actor(parent, :writer, fn -> Messaging.add_reaction(c.source.id, "👍", c.administrator) end)

    assert_receive {:writer_backend, writer_backend}, 5_000
    refute writer_backend == eraser_backend
    {query, blockers} = wait_for_lock(writer_backend)
    # Before correction this is INSERT INTO message_reactions waiting on its
    # parent FK. Correction retains current active Message SHARE before INSERT.
    assert String.contains?(query, ~s(FROM "messages"))
    assert String.contains?(query, "FOR SHARE")
    assert eraser_backend in blockers
    send(eraser_pid, {:release_barrier, release})
    assert {:ok, %{request: %{status: :completed}}} = Task.await(eraser, 10_000)
    assert {:error, :not_found} = Task.await(writer, 10_000)

    unboxed(fn ->
      refute Repo.exists?(from(r in Reaction, where: r.message_id == ^c.source.id))
      assert {:error, :not_found} = Messaging.add_reaction(c.source.id, "👍", c.administrator)
      assert {:error, :not_found} = Messaging.remove_reaction(c.source.id, "👍", c.administrator)
      refute Repo.exists?(from(r in Reaction, where: r.message_id == ^c.source.id))
    end)
  end

  for operation <- [:add, :remove] do
    @operation operation
    @tag timeout: 30_000
    test "real reaction #{@operation} retains active Message until owner completion can sweep" do
      c = fixture()

      if @operation == :remove do
        assert {:ok, _} =
                 unboxed(fn -> Messaging.add_reaction(c.source.id, "👍", c.administrator) end)
      end

      parent = self()

      predicate = fn query ->
        String.contains?(query, ~s("message_reactions")) and
          String.starts_with?(query, if(@operation == :add, do: "INSERT", else: "DELETE"))
      end

      writer = actor(parent, :writer, fn -> invoke(@operation, c) end, predicate)
      assert_receive {:writer_backend, writer_backend}, 5_000
      assert_receive {:writer_barrier, writer_pid, release}, 5_000
      eraser = actor(parent, :eraser, fn -> complete(c.claim) end)
      assert_receive {:eraser_backend, eraser_backend}, 5_000
      {query, blockers} = wait_for_lock(eraser_backend)
      assert String.contains?(query, ~s(FROM "messages"))
      assert writer_backend in blockers
      send(writer_pid, {:release_barrier, release})
      result = Task.await(writer, 10_000)
      if @operation == :add, do: assert(match?({:ok, _}, result)), else: assert(result == :ok)
      assert {:ok, %{request: %{status: :completed}}} = Task.await(eraser, 10_000)

      unboxed(fn ->
        refute Repo.exists?(from(r in Reaction, where: r.message_id == ^c.source.id))
      end)
    end
  end

  defp invoke(:add, c), do: Messaging.add_reaction(c.source.id, "👍", c.administrator)
  defp invoke(:remove, c), do: Messaging.remove_reaction(c.source.id, "👍", c.administrator)

  defp complete(claim) do
    Governance.complete_deletion_request(
      claim.request_id,
      claim.expected_version,
      %{deleted_object_count: 0},
      RuntimePorts.job_worker!(:deletion)
    )
  end

  defp fixture() do
    c =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        administrator = Fixtures.step_up(account)

        %{user: user} =
          Fixtures.user_fixture(account, %{
            password_hash: CommsCore.Security.Password.hash(@password)
          })

        {:ok, authentication} =
          Accounts.authenticate_view(account.tenant.slug, user.email, @password, %{})

        target = %{
          tenant: account.tenant,
          user: user,
          device: authentication.device,
          session: Repo.get!(Session, authentication.session_id)
        }

        subject = Fixtures.subject(target)

        {:ok, conversation} =
          Conversations.create(
            %{kind: "group", title: "Private finality race", member_ids: [user.id]},
            administrator
          )

        {:ok, source} =
          Messaging.accept_message(
            %{
              tenant_id: account.tenant.id,
              conversation_id: conversation.id,
              sender_user_id: account.user.id,
              sender_device_id: account.device.id,
              client_message_id: "unrelated-source",
              body: "Unrelated retained source",
              attachment_ids: []
            },
            administrator
          )

        {scope_key, scope_id} = {:message_id, source.id}

        deletion_attrs =
          %{target_type: :message, reason: "Synthetic governed private finality proof"}
          |> Map.put(scope_key, scope_id)

        {:ok, %{request: request}} =
          Governance.create_deletion_request(deletion_attrs, administrator)

        {:ok, approved} =
          Governance.transition_deletion_request(
            request.id,
            %{
              version: request.lock_version,
              status: :approved,
              transition_reason: "Synthetic account deletion verified"
            },
            administrator
          )

        {:ok, claim} =
          Governance.claim_deletion_request(approved.id, RuntimePorts.job_worker!(:deletion))

        %{
          tenant_id: account.tenant.id,
          target: target,
          subject: subject,
          administrator: administrator,
          conversation: conversation,
          source: source,
          claim: claim
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          event_ids =
            Repo.all(from(e in OutboxEvent, where: e.tenant_id == ^c.tenant_id, select: e.id))

          Repo.delete_all(
            from(job in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^c.tenant_id) or
                  fragment("?->>'request_id' = ?", job.args, ^c.claim.request_id) or
                  fragment("?->>'deletion_request_id' = ?", job.args, ^c.claim.request_id) or
                  fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids)
            )
          )

          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^c.tenant_id))
        end)
      end)
    end)

    c
  end

  defp actor(parent, name, operation, predicate \\ nil) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {tag(name, :backend), backend})
          handler = {__MODULE__, make_ref()}
          release = make_ref()
          if predicate, do: attach_barrier(handler, parent, name, release, predicate)

          try do
            operation.()
          after
            if predicate, do: :telemetry.detach(handler)
          end
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp attach_barrier(handler, parent, name, release, predicate) do
    pid = self()

    :ok =
      :telemetry.attach(
        handler,
        @query_event,
        fn _, _, metadata, _ ->
          query = Map.get(metadata, :query)

          if self() == pid and Repo.in_transaction?() and is_binary(query) and
               predicate.(query) and not Process.get(handler, false) do
            Process.put(handler, true)
            send(parent, {tag(name, :barrier), self(), release})

            receive do
              {:release_barrier, ^release} -> :ok
            after
              10_000 -> raise "private finality barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp tag(:writer, :backend), do: :writer_backend
  defp tag(:writer, :barrier), do: :writer_barrier
  defp tag(:eraser, :backend), do: :eraser_backend
  defp tag(:eraser, :barrier), do: :eraser_barrier

  defp wait_for_lock(backend, attempts \\ 200)

  defp wait_for_lock(_, 0),
    do: flunk("actual second PG actor did not wait on retained writer authority")

  defp wait_for_lock(backend, attempts) do
    result =
      unboxed(fn ->
        Repo.query!(
          "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
          [backend]
        )
      end)

    case result.rows do
      [[query, blockers]] ->
        {query, blockers}

      _ ->
        Process.sleep(25)
        wait_for_lock(backend, attempts - 1)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
