defmodule CommsCore.GovernanceLateContentFinalityTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Governance, Messaging, Repo, RuntimePorts}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Messaging.{Message, MessageRevision}
  alias CommsCore.Whiteboards.WriteFence
  alias CommsCore.TrustGovernanceTestSupport
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @moduletag :governance

  defmodule RepairStorage do
    def delete_object(request) do
      send(Application.fetch_env!(:comms_integrations, :governance_repair_test_owner), {
        :repair_object_deleted,
        request
      })

      :ok
    end
  end

  @tag timeout: 30_000
  test "completion drains a current writer before selecting the final erasure scope" do
    fixture = committed_fixture()
    parent = self()
    release = make_ref()

    writer =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            assert {:ok, _grant} = Accounts.lock_content_write_grant(fixture.target_subject)
            WriteFence.lock_author!(fixture.account.tenant.id, fixture.target.id)
            send(parent, {:writer_retained, self(), backend_pid()})

            receive do
              {:write_and_commit, ^release} -> :ok
            after
              10_000 -> raise "late-content writer barrier timed out"
            end

            assert {:ok, message} =
                     Messaging.accept_message(
                       %{
                         tenant_id: fixture.account.tenant.id,
                         conversation_id: fixture.conversation.id,
                         sender_user_id: fixture.target.id,
                         sender_device_id: fixture.target_subject.device_id,
                         client_message_id: "governance-late-content",
                         body: "late private original"
                       },
                       fixture.target_subject
                     )

            assert {:ok, _edited} =
                     Messaging.edit_message(
                       message.id,
                       "late private replacement",
                       fixture.target_subject
                     )

            message.id
          end)
        end)
      end)

    try do
      assert_receive {:writer_retained, writer_pid, writer_backend}, 5_000
      assert writer_pid == writer.pid

      eraser =
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:eraser_started, self(), backend_pid()})

            Governance.complete_deletion_request(
              fixture.claim.request_id,
              fixture.claim.expected_version,
              %{deleted_object_count: 0},
              RuntimePorts.job_worker!(:deletion)
            )
          end)
        end)

      try do
        assert_receive {:eraser_started, eraser_pid, eraser_backend}, 5_000
        assert eraser_pid == eraser.pid
        refute writer_backend == eraser_backend

        # The old scan-first implementation reaches the author advisory only
        # after choosing/tombstoning messages. The corrected implementation
        # must wait at the upfront identity fence before choosing that scope.
        blocker =
          await_erasure_blocker(
            eraser_backend,
            writer_backend,
            System.monotonic_time(:millisecond) + 5_000
          )

        send(writer.pid, {:write_and_commit, release})
        assert {:ok, late_message_id} = Task.await(writer, 10_000)

        assert {:ok, %{request: %{status: :completed}, revoked_session_ids: revoked}} =
                 Task.await(eraser, 10_000)

        assert fixture.target_subject.session_id in revoked

        unboxed(fn ->
          assert Repo.get!(DeletionRequest, fixture.claim.request_id).status == :completed
          assert Repo.get!(User, fixture.target.id).status == :deleted
          assert Repo.get!(Session, fixture.target_subject.session_id).revoked_at

          late = Repo.get!(Message, late_message_id)
          assert late.status == :deleted
          assert is_nil(late.body)
          assert late.metadata == %{}
          assert late.deleted_at

          refute Repo.exists?(from(r in MessageRevision, where: r.message_id == ^late_message_id))

          events =
            Repo.all(
              from(e in OutboxEvent,
                where:
                  e.tenant_id == ^fixture.account.tenant.id and
                    e.aggregate_id == ^late_message_id
              )
            )

          assert length(events) == 2
          assert Enum.all?(events, &(&1.payload == %{"content_erased" => true}))
        end)

        # Check final state first so the old order demonstrates the actual
        # surviving-content failure rather than only a query-order mismatch.
        assert blocker == :identity
      after
        send(writer.pid, {:write_and_commit, release})
        Task.shutdown(eraser, :brutal_kill)
      end
    after
      send(writer.pid, {:write_and_commit, release})
      Task.shutdown(writer, :brutal_kill)
    end
  end

  test "historical writer gaps requeue actual object deletion before recording finality proof" do
    fixture = committed_fixture()

    previous_adapter = Application.get_env(:comms_integrations, :object_storage_adapter)
    previous_owner = Application.get_env(:comms_integrations, :governance_repair_test_owner)
    Application.put_env(:comms_integrations, :object_storage_adapter, RepairStorage)
    Application.put_env(:comms_integrations, :governance_repair_test_owner, self())

    on_exit(fn ->
      restore_env(:object_storage_adapter, previous_adapter)
      restore_env(:governance_repair_test_owner, previous_owner)
    end)

    unboxed(fn ->
      worker = RuntimePorts.job_worker!(:deletion)
      reconciler = RuntimePorts.job_worker!(:erasure_reconciler)

      assert {:ok, %{request: completed}} =
               Governance.complete_deletion_request(
                 fixture.claim.request_id,
                 fixture.claim.expected_version,
                 %{deleted_object_count: 0},
                 worker
               )

      # Reproduce persisted pre-fix state: the old completion evidence is
      # present, but a writer committed body/revision/object after its scan.
      historical_evidence =
        Map.drop(completed.evidence, [
          :writer_fence_erasure_version,
          "writer_fence_erasure_version"
        ])

      Repo.update_all(from(r in DeletionRequest, where: r.id == ^completed.id),
        set: [evidence: historical_evidence]
      )

      message =
        Repo.insert!(%Message{
          tenant_id: fixture.account.tenant.id,
          conversation_id: fixture.conversation.id,
          sender_user_id: fixture.target.id,
          sender_device_id: fixture.target_subject.device_id,
          client_message_id: "historical-writer-content",
          conversation_sequence: 1,
          body: "historical missed private body"
        })

      Repo.insert!(%MessageRevision{
        tenant_id: fixture.account.tenant.id,
        message_id: message.id,
        editor_user_id: fixture.target.id,
        revision: 1,
        body: "historical missed private revision"
      })

      attachment =
        Repo.insert!(%Attachment{
          tenant_id: fixture.account.tenant.id,
          owner_user_id: fixture.target.id,
          message_id: message.id,
          object_key: fixture.account.tenant.id <> "/historical-repair/document",
          object_version_id: "historical-version",
          file_name: "private-document.txt",
          content_type: "text/plain",
          byte_size: 12,
          status: :uploaded
        })

      parent = self()
      release = make_ref()
      handler = {__MODULE__, release}

      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if Process.get(:governance_repair_snapshot) == release and
               String.contains?(metadata.query, ~s(FROM "deletion_requests")) and
               String.contains?(metadata.query, "writer_fence_erasure_version") do
            send(parent, {:historical_snapshot_selected, self()})

            receive do
              {:continue_repair, ^release} -> :ok
            after
              5_000 -> raise "historical-repair snapshot barrier timed out"
            end
          end
        end,
        nil
      )

      stale_repair =
        Task.async(fn ->
          unboxed(fn ->
            Process.put(:governance_repair_snapshot, release)
            send(parent, {:repair_connection, backend_pid()})
            Governance.reconcile_completed_erasure(reconciler, 1)
          end)
        end)

      try do
        assert_receive {:repair_connection, stale_backend}, 5_000
        refute stale_backend == backend_pid()
        assert_receive {:historical_snapshot_selected, stale_pid}, 5_000
        assert stale_pid == stale_repair.pid

        assert {:ok, %{repaired: 0, has_more: true}} =
                 Governance.reconcile_completed_erasure(reconciler, 1)

        already_queued = Repo.get!(DeletionRequest, completed.id)
        send(stale_repair.pid, {:continue_repair, release})

        assert {:ok, %{repaired: 0, has_more: true}} = Task.await(stale_repair, 5_000)
        skipped = Repo.get!(DeletionRequest, completed.id)
        assert skipped.lock_version == already_queued.lock_version
        assert skipped.evidence == already_queued.evidence
        assert skipped.status == :in_progress
      after
        send(stale_repair.pid, {:continue_repair, release})
        Task.shutdown(stale_repair, :brutal_kill)
        :telemetry.detach(handler)
      end

      queued = Repo.get!(DeletionRequest, completed.id)
      assert queued.status == :in_progress
      assert queued.lock_version > completed.lock_version
      assert is_nil(queued.completed_at)
      assert queued.execution_error == "writer_fence_repair_pending"
      assert is_nil(queued.evidence["writer_fence_erasure_version"])
      assert queued.evidence["deleted_object_count"] == 0
      assert queued.evidence["historical_completed_at"]
      assert Repo.get!(Attachment, attachment.id).status == :uploaded
      refute_receive {:repair_object_deleted, _}

      assert {:error, :stale_version} =
               Governance.complete_deletion_request(
                 queued.id,
                 completed.lock_version,
                 %{deleted_object_count: 0},
                 worker
               )

      # The real registered worker claims the fresh scope and obtains its
      # evidence from an observed storage effect, rather than the old count.
      assert :ok = worker.perform(%Oban.Job{args: %{"deletion_request_id" => queued.id}})

      assert_receive {:repair_object_deleted,
                      %{
                        tenant_id: tenant_id,
                        object_key: object_key,
                        object_version_id: "historical-version"
                      }}

      assert tenant_id == fixture.account.tenant.id
      assert object_key == attachment.object_key
      repaired = Repo.get!(DeletionRequest, queued.id)
      assert repaired.status == :completed
      assert repaired.evidence["writer_fence_erasure_version"] == 1
      assert repaired.evidence["deleted_object_count"] == 1
      assert Repo.get!(Attachment, attachment.id).status == :deleted
      assert is_nil(Repo.get!(Message, message.id).body)
      refute Repo.exists?(from(r in MessageRevision, where: r.message_id == ^message.id))

      assert {:ok, %{repaired: 0, has_more: false}} =
               Governance.reconcile_completed_erasure(reconciler, 1)
    end)
  end

  defp committed_fixture do
    fixture =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        subject = Fixtures.step_up(account)
        %{user: target} = Fixtures.user_fixture(account)

        target_subject =
          TrustGovernanceTestSupport.authenticated_subject(account, target, "Late-content writer")

        assert {:ok, conversation} =
                 Conversations.create(
                   %{title: "Current writer erasure", kind: "group", member_ids: [target.id]},
                   subject
                 )

        assert {:ok, %{request: request}} =
                 Governance.create_deletion_request(
                   %{target_type: "user", subject_user_id: target.id, reason: "Verified erasure"},
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

        %{
          account: account,
          target: target,
          target_subject: target_subject,
          conversation: conversation,
          claim: claim
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        tenant_id = fixture.account.tenant.id

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'tenant_id' = ?", j.args, ^tenant_id))
        )

        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
      end)
    end)

    fixture
  end

  defp await_erasure_blocker(eraser_backend, writer_backend, deadline) do
    %{rows: rows} =
      unboxed(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT wait_event_type, query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1",
          [eraser_backend]
        )
      end)

    case rows do
      [["Lock", query, blockers]] when is_binary(query) and is_list(blockers) ->
        cond do
          writer_backend not in blockers ->
            retry_blocker(eraser_backend, writer_backend, deadline)

          String.contains?(query, ~s(FROM "users")) or
              String.contains?(query, ~s(UPDATE "sessions")) ->
            :identity

          String.contains?(query, "pg_advisory_xact_lock") ->
            :late_author

          true ->
            retry_blocker(eraser_backend, writer_backend, deadline)
        end

      _ ->
        retry_blocker(eraser_backend, writer_backend, deadline)
    end
  end

  defp retry_blocker(eraser_backend, writer_backend, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("eraser did not wait on the retained writer's real identity/author fence")
    else
      Process.sleep(10)
      await_erasure_blocker(eraser_backend, writer_backend, deadline)
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp restore_env(key, nil), do: Application.delete_env(:comms_integrations, key)
  defp restore_env(key, value), do: Application.put_env(:comms_integrations, key, value)
end
