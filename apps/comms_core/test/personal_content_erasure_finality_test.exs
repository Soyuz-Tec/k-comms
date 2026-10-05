defmodule CommsCore.PersonalContentErasureFinalityTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias CommsCore.{Accounts, Conversations, Governance, Messaging, Repo, RuntimePorts}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Conversations.Conversation
  alias CommsCore.Messaging.{Message, MessageRevision}
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging.PersonalContent.{Draft, SavedItem}
  alias CommsTestSupport.Fixtures

  @query_event [:comms_core, :repo, :query]
  @password "synthetic-private-erasure-target-password"
  @moduletag :integration
  @moduletag :governance
  @moduletag :concurrency

  for operation <- [:draft, :save] do
    @operation operation
    test "actual #{@operation} admission commits before waiting governance and is included in final erasure" do
      c = fixture()
      parent = self()

      writer = actor(parent, :writer, fn -> write(@operation, c) end, &membership_query?/1)
      assert_receive {:writer_backend, writer_backend}, 5_000
      assert_receive {:writer_barrier, writer_pid, writer_release}, 5_000

      eraser = actor(parent, :eraser, fn -> complete(c.claim) end)
      assert_receive {:eraser_backend, eraser_backend}, 5_000
      refute writer_backend == eraser_backend

      # In the pre-fix implementation no actor/session row is retained, so the
      # real eraser can finish while this actual admitted writer is paused.
      # Observe actual PostgreSQL blocking; a delayed Task alone is not proof.
      {query, blockers} = wait_for_lock(eraser_backend)
      assert String.contains?(query, ~s("users")) or String.contains?(query, ~s("sessions"))
      assert writer_backend in blockers
      refute Task.yield(eraser, 0)

      send(writer_pid, {:release_barrier, writer_release})
      assert {:ok, _} = Task.await(writer, 10_000)

      assert {:ok, %{request: %{status: :completed}, revoked_session_ids: revoked}} =
               Task.await(eraser, 10_000)

      assert c.target.session.id in revoked

      unboxed(fn ->
        assert_private_empty(c)
        assert Repo.get!(User, c.target.user.id).status == :deleted
        assert Repo.get!(Session, c.target.session.id).revoked_at
        assert Repo.get!(DeletionRequest, c.claim.request_id).status == :completed
        assert Repo.get!(Message, c.source.id).body == "Unrelated retained source"
        assert {:error, :forbidden} = write(@operation, c)
        assert_private_empty(c)
      end)
    end

    test "owner #{@operation} erasure waits on the same private advisory after actual insertion" do
      c = fixture()
      parent = self()
      table = if @operation == :draft, do: "message_drafts", else: "message_saved_items"
      predicate = fn query -> String.contains?(query, ~s(INSERT INTO "#{table}")) end
      writer = actor(parent, :writer, fn -> write(@operation, c) end, predicate)
      assert_receive {:writer_backend, writer_backend}, 5_000
      assert_receive {:writer_barrier, writer_pid, writer_release}, 5_000

      eraser =
        actor(parent, :eraser, fn ->
          Repo.transaction(fn ->
            Messaging.erase_personal_content(c.tenant_id, :user, c.target.user.id)
          end)
        end)

      assert_receive {:eraser_backend, eraser_backend}, 5_000
      refute writer_backend == eraser_backend
      {query, blockers} = wait_for_lock(eraser_backend)
      assert String.contains?(query, "pg_advisory_xact_lock")
      assert writer_backend in blockers

      send(writer_pid, {:release_barrier, writer_release})
      assert {:ok, _} = Task.await(writer, 10_000)
      assert {:ok, :ok} = Task.await(eraser, 10_000)
      unboxed(fn -> assert_private_empty(c) end)
    end
  end

  for operation <- [:draft, :save] do
    @operation operation
    @tag timeout: 30_000
    test "actual #{@operation} admission rejects clock expiry reached during its retained parent wait" do
      c = fixture()
      parent = self()

      holder =
        actor(parent, :eraser, fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(conversation in Conversation,
                where: conversation.id == ^c.conversation.id,
                lock: "FOR UPDATE"
              )
            )

            send(parent, {:parent_retained, self()})

            receive do
              :release_parent -> :ok
            after
              10_000 -> raise "content parent expiry holder timed out"
            end
          end)
        end)

      assert_receive {:eraser_backend, holder_backend}, 5_000
      assert_receive {:parent_retained, holder_pid}, 5_000

      expires_at =
        DateTime.utc_now() |> DateTime.add(2, :second) |> DateTime.truncate(:microsecond)

      unboxed(fn ->
        Repo.update_all(from(session in Session, where: session.id == ^c.target.session.id),
          set: [expires_at: expires_at]
        )
      end)

      writer = actor(parent, :writer, fn -> write(@operation, c) end)
      assert_receive {:writer_backend, writer_backend}, 5_000
      {query, blockers} = wait_for_lock(writer_backend)
      assert String.contains?(query, "conversations")
      assert holder_backend in blockers
      wait_for_expiry(expires_at)
      send(holder_pid, :release_parent)
      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {:error, :forbidden} = Task.await(writer, 5_000)
      unboxed(fn -> assert_private_empty(c) end)
    end
  end

  @tag timeout: 30_000
  test "actual draft writer retains its parent before conversation completion archives and sweeps" do
    c = fixture(:conversation)
    parent = self()
    writer = actor(parent, :writer, fn -> write(:draft, c) end, &membership_query?/1)
    assert_receive {:writer_backend, writer_backend}, 5_000
    assert_receive {:writer_barrier, writer_pid, release}, 5_000
    eraser = actor(parent, :eraser, fn -> complete(c.claim) end)
    assert_receive {:eraser_backend, eraser_backend}, 5_000
    refute writer_backend == eraser_backend
    {query, blockers} = wait_for_lock(eraser_backend)
    assert String.contains?(query, "conversations")
    assert writer_backend in blockers
    send(writer_pid, {:release_barrier, release})
    assert {:ok, _} = Task.await(writer, 10_000)
    assert {:ok, %{request: %{status: :completed}}} = Task.await(eraser, 10_000)

    unboxed(fn ->
      assert_private_empty(c)
      assert Repo.get!(User, c.target.user.id).status == :active
      assert {:error, _} = write(:draft, c)
      assert_private_empty(c)
    end)
  end

  @tag timeout: 30_000
  test "message completion retains edited parent before scanning its uncommitted revision" do
    c = fixture(:message)
    parent = self()
    predicate = fn query -> String.starts_with?(query, ~s(UPDATE "messages")) end

    writer =
      actor(
        parent,
        :writer,
        fn ->
          Messaging.edit_message(
            c.source.id,
            "Private replacement pending commit",
            c.administrator
          )
        end,
        predicate
      )

    assert_receive {:writer_backend, writer_backend}, 5_000
    assert_receive {:writer_barrier, writer_pid, release}, 5_000
    eraser = actor(parent, :eraser, fn -> complete(c.claim) end)
    assert_receive {:eraser_backend, eraser_backend}, 5_000
    {query, blockers} = wait_for_lock(eraser_backend)
    assert String.contains?(query, "messages")
    assert writer_backend in blockers
    send(writer_pid, {:release_barrier, release})
    assert {:ok, _} = Task.await(writer, 10_000)
    assert {:ok, %{request: %{status: :completed}}} = Task.await(eraser, 10_000)

    unboxed(fn ->
      assert Repo.get!(Message, c.source.id).body == nil
      refute Repo.exists?(from(r in MessageRevision, where: r.message_id == ^c.source.id))

      events =
        Repo.all(
          from(e in OutboxEvent,
            where: e.tenant_id == ^c.tenant_id and e.aggregate_id == ^c.source.id
          )
        )

      assert length(events) == 2
      assert Enum.all?(events, &(&1.payload == %{"content_erased" => true}))
    end)
  end

  defp write(:draft, c),
    do:
      Messaging.put_draft(
        c.conversation.id,
        %{body: "Private pending text", expected_version: 0},
        c.subject
      )

  defp write(:save, c), do: Messaging.save_message(c.source.id, c.subject)

  defp complete(claim) do
    Governance.complete_deletion_request(
      claim.request_id,
      claim.expected_version,
      %{deleted_object_count: 0},
      RuntimePorts.job_worker!(:deletion)
    )
  end

  defp fixture(target_type \\ :user) do
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

        {scope_key, scope_id} =
          case target_type do
            :user -> {:subject_user_id, user.id}
            :conversation -> {:conversation_id, conversation.id}
            :message -> {:message_id, source.id}
          end

        deletion_attrs =
          %{target_type: target_type, reason: "Synthetic governed private finality proof"}
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

  defp assert_private_empty(c) do
    refute Repo.exists?(
             from(d in Draft,
               where: d.tenant_id == ^c.tenant_id and d.user_id == ^c.target.user.id
             )
           )

    refute Repo.exists?(
             from(s in SavedItem,
               where: s.tenant_id == ^c.tenant_id and s.user_id == ^c.target.user.id
             )
           )
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

  defp membership_query?(query), do: String.contains?(query, ~s(FROM "conversation_memberships"))
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

  defp wait_for_expiry(expires_at, attempts \\ 300)
  defp wait_for_expiry(_, 0), do: flunk("synthetic authority did not expire")

  defp wait_for_expiry(expires_at, attempts) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
      :ok
    else
      Process.sleep(10)
      wait_for_expiry(expires_at, attempts - 1)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
