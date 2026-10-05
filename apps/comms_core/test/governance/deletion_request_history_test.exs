defmodule CommsCore.Governance.DeletionRequestHistoryTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Audit, Governance}
  alias CommsCore.Audit.TestSupport
  alias CommsCore.Governance.{DeletionRequest, HistoryCursor}
  alias CommsTestSupport.Fixtures

  setup do
    previous = Application.get_env(:comms_core, :governance_history_cursor_key)

    Application.put_env(
      :comms_core,
      :governance_history_cursor_key,
      "synthetic-history-test-key-only-32-bytes"
    )

    on_exit(fn -> restore_key(previous) end)
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    target = Fixtures.user_fixture(account)

    {:ok, result} =
      Governance.create_deletion_request(
        %{
          target_type: "user",
          subject_user_id: target.user.id,
          reason: "Verified synthetic erasure request"
        },
        subject
      )

    %{account: account, subject: subject, target: target, request: result.request}
  end

  test "pages actual lifecycle events chronologically and exports the same fixed history", ctx do
    assert {:ok, approved} =
             Governance.transition_deletion_request(
               ctx.request.id,
               %{
                 version: 1,
                 status: "approved",
                 transition_reason: "Verified by synthetic owner"
               },
               ctx.subject
             )

    assert {:ok, claim} =
             Governance.claim_deletion_request(approved.id, CommsWorkers.DeletionWorker)

    assert {:ok, _failed} =
             Governance.record_deletion_failure(
               approved.id,
               {:provider, "private provider object"},
               CommsWorkers.DeletionWorker
             )

    current = Repo.get!(DeletionRequest, approved.id)

    assert {:ok, _completed} =
             Governance.complete_deletion_request(
               approved.id,
               current.lock_version,
               %{deleted_object_count: 0},
               CommsWorkers.DeletionWorker
             )

    assert claim.expected_version < current.lock_version

    assert {:ok, first} =
             Governance.deletion_request_timeline(ctx.request.id, %{limit: 2}, ctx.subject)

    assert Enum.map(first.events, & &1.action) == [
             "deletion_request.create",
             "deletion_request.approved"
           ]

    assert first.coverage.state == :available
    assert first.next_cursor

    assert {:ok, second} =
             Governance.deletion_request_timeline(
               ctx.request.id,
               %{cursor: first.next_cursor},
               ctx.subject
             )

    assert Enum.map(second.events, & &1.action) == [
             "deletion_request.claim",
             "deletion_request.failure"
           ]

    assert Enum.at(second.events, 1).error_code == :provider_failure

    assert {:ok, third} =
             Governance.deletion_request_timeline(
               ctx.request.id,
               %{cursor: second.next_cursor},
               ctx.subject
             )

    assert Enum.map(third.events, & &1.action) == ["deletion_request.completed"]
    refute third.next_cursor

    assert {:ok, export} =
             Governance.export_deletion_request_history(
               ctx.request.id,
               %{snapshot: first.snapshot},
               ctx.subject
             )

    assert export.count == 5 and not export.truncated
    refute export.csv =~ "private provider object"
    assert export.csv =~ "writer_fence_erasure_version"

    assert 1 ==
             Audit.count(%{
               tenant_id: ctx.account.tenant.id,
               resource_id: ctx.request.id,
               action: "deletion_request.history_export"
             })
  end

  test "only allowlisted integer evidence and explicit error enums are disclosed", ctx do
    secret = "private-provider-password-and-object-key"

    metadata = %{
      attempt: 2,
      version: 3,
      error_code: secret,
      transition_reason: secret,
      evidence: %{
        media_erasure_version: 1,
        deleted_object_count: 4,
        executor: secret,
        target_digest: secret,
        provider_key: secret,
        attachments_deleted: secret,
        messages_tombstoned: -1
      }
    }

    TestSupport.insert!(%{
      tenant_id: ctx.account.tenant.id,
      actor_user_id: ctx.account.user.id,
      action: "deletion_request.completed",
      resource_type: "deletion_request",
      resource_id: ctx.request.id,
      metadata: metadata
    })

    Repo.get!(DeletionRequest, ctx.request.id)
    |> Ecto.Changeset.change(
      execution_error: secret,
      evidence: metadata.evidence
    )
    |> Repo.update!()

    assert {:ok, timeline} =
             Governance.deletion_request_timeline(ctx.request.id, %{}, ctx.subject)

    event = List.last(timeline.events)
    assert event.error_code == :unavailable
    assert event.proof_versions == %{"media_erasure_version" => 1}
    assert event.counts == %{"deleted_object_count" => 4}
    assert timeline.request.execution_error == :unavailable

    assert timeline.request.evidence == %{
             "media_erasure_version" => 1,
             "deleted_object_count" => 4
           }

    refute inspect(timeline) =~ secret

    assert {:ok, csv} =
             Governance.export_deletion_request_history(ctx.request.id, %{}, ctx.subject)

    refute csv.csv =~ secret
  end

  test "scope rejects foreign requests/cursors and omits foreign actors and unrelated audit rows",
       ctx do
    other = Fixtures.account_fixture()

    TestSupport.insert!(%{
      tenant_id: ctx.account.tenant.id,
      actor_user_id: other.user.id,
      action: "deletion_request.claim",
      resource_type: "deletion_request",
      resource_id: ctx.request.id,
      metadata: %{attempt: 1}
    })

    TestSupport.insert!(%{
      tenant_id: other.tenant.id,
      action: "deletion_request.claim",
      resource_type: "deletion_request",
      resource_id: ctx.request.id,
      metadata: %{attempt: 99}
    })

    TestSupport.insert!(%{
      tenant_id: ctx.account.tenant.id,
      action: "deletion_request.claim",
      resource_type: "deletion_request",
      resource_id: Ecto.UUID.generate(),
      metadata: %{attempt: 88}
    })

    assert {:ok, first} =
             Governance.deletion_request_timeline(ctx.request.id, %{limit: 1}, ctx.subject)

    assert {:ok, second} =
             Governance.deletion_request_timeline(
               ctx.request.id,
               %{cursor: first.next_cursor},
               ctx.subject
             )

    assert [%{attempt: 1, actor: %{kind: :unavailable, user_id: nil, display_name: nil}}] =
             second.events

    assert {:error, :not_found} =
             Governance.deletion_request_timeline(ctx.request.id, %{}, Fixtures.step_up(other))

    assert {:error, :invalid_history_cursor} =
             Governance.deletion_request_timeline(
               Ecto.UUID.generate(),
               %{cursor: first.next_cursor},
               ctx.subject
             )

    assert {:error, :invalid_history_cursor} =
             Governance.export_deletion_request_history(
               ctx.request.id,
               %{snapshot: first.snapshot},
               Fixtures.step_up(other)
             )
  end

  test "new equal/backdated source events stay outside an existing signed snapshot", ctx do
    assert {:ok, first} = Governance.deletion_request_timeline(ctx.request.id, %{}, ctx.subject)

    for timestamp <- [
          hd(first.events).inserted_at,
          DateTime.add(hd(first.events).inserted_at, -60, :second)
        ] do
      TestSupport.insert!(%{
        tenant_id: ctx.account.tenant.id,
        action: "deletion_request.claim",
        resource_type: "deletion_request",
        resource_id: ctx.request.id,
        metadata: %{attempt: 1},
        inserted_at: timestamp
      })
    end

    assert {:ok, old} =
             Governance.deletion_request_timeline(
               ctx.request.id,
               %{snapshot: first.snapshot},
               ctx.subject
             )

    assert Enum.map(old.events, & &1.id) == Enum.map(first.events, & &1.id)

    assert {:ok, csv} =
             Governance.export_deletion_request_history(
               ctx.request.id,
               %{snapshot: first.snapshot},
               ctx.subject
             )

    assert csv.count == 1
    assert {:ok, fresh} = Governance.deletion_request_timeline(ctx.request.id, %{}, ctx.subject)
    assert length(fresh.events) == 3
  end

  test "signatures, expiry, page limit and key availability fail closed", ctx do
    TestSupport.insert!(%{
      tenant_id: ctx.account.tenant.id,
      action: "deletion_request.claim",
      resource_type: "deletion_request",
      resource_id: ctx.request.id,
      metadata: %{attempt: 1}
    })

    assert {:ok, first} =
             Governance.deletion_request_timeline(ctx.request.id, %{limit: 1}, ctx.subject)

    assert {:error, :invalid_history_cursor} =
             Governance.deletion_request_timeline(
               ctx.request.id,
               %{cursor: first.next_cursor <> "x"},
               ctx.subject
             )

    assert {:error, :invalid_history_cursor} =
             Governance.deletion_request_timeline(
               ctx.request.id,
               %{cursor: first.next_cursor, limit: 2},
               ctx.subject
             )

    assert {:error, :invalid_history_limit} =
             Governance.deletion_request_timeline(ctx.request.id, %{limit: 51}, ctx.subject)

    assert {:error, :invalid_history_limit} =
             Governance.export_deletion_request_history(
               ctx.request.id,
               %{limit: 5_001},
               ctx.subject
             )

    {:ok, cursor} =
      HistoryCursor.open(first.snapshot, :snapshot, ctx.account.tenant.id, ctx.request.id)

    old_time = DateTime.add(cursor.observed_at, -7_200, :second)

    {:ok, expired} =
      HistoryCursor.seal(
        %{cursor | observed_at: old_time, expires_at: DateTime.to_unix(old_time) + 3_600},
        :snapshot
      )

    assert {:error, :invalid_history_cursor} =
             Governance.export_deletion_request_history(
               ctx.request.id,
               %{snapshot: expired},
               ctx.subject
             )

    Application.delete_env(:comms_core, :governance_history_cursor_key)

    assert {:error, :history_unavailable} =
             Governance.deletion_request_timeline(ctx.request.id, %{}, ctx.subject)
  end

  test "CSV neutralizes spreadsheet formulas and excludes authored reasons", ctx do
    ctx.account.user
    |> Ecto.Changeset.change(display_name: "  =CMD(\"synthetic\")")
    |> Repo.update!()

    assert {:ok, csv} =
             Governance.export_deletion_request_history(ctx.request.id, %{}, ctx.subject)

    assert csv.csv =~ ~s|"'  =CMD(""synthetic"")"|
    refute csv.csv =~ ctx.request.reason
    assert csv.filename == "deletion-request-history.csv"
    assert csv.maximum_rows == 5_000
  end

  test "missing historical audit is unavailable or partial and never synthesized from current state",
       ctx do
    request =
      %DeletionRequest{}
      |> DeletionRequest.changeset(%{
        tenant_id: ctx.account.tenant.id,
        requested_by_user_id: ctx.account.user.id,
        subject_user_id: ctx.target.user.id,
        target_type: :user,
        reason: "Historical synthetic request",
        status: :completed,
        evidence: %{}
      })
      |> Repo.insert!()

    assert {:ok, unavailable} = Governance.deletion_request_timeline(request.id, %{}, ctx.subject)
    assert unavailable.request.status == :completed
    assert unavailable.events == []
    assert unavailable.coverage.state == :unavailable
    refute unavailable.coverage.origin_present

    TestSupport.insert!(%{
      tenant_id: ctx.account.tenant.id,
      action: "deletion_request.completed",
      resource_type: "deletion_request",
      resource_id: request.id,
      metadata: %{version: 9, evidence: %{derived_erasure_version: 1}}
    })

    assert {:ok, partial} = Governance.deletion_request_timeline(request.id, %{}, ctx.subject)
    assert partial.coverage.state == :partial
    assert [%{action: "deletion_request.completed", version: 9}] = partial.events
  end

  test "fresh role and step-up remain required for every snapshot page and export", ctx do
    assert {:ok, first} = Governance.deletion_request_timeline(ctx.request.id, %{}, ctx.subject)
    assert :ok = Accounts.revoke_session(ctx.account.session.id, ctx.account.user.id)

    assert {:error, :forbidden} =
             Governance.deletion_request_timeline(
               ctx.request.id,
               %{snapshot: first.snapshot},
               ctx.subject
             )

    assert {:error, :forbidden} =
             Governance.export_deletion_request_history(
               ctx.request.id,
               %{snapshot: first.snapshot},
               ctx.subject
             )
  end

  defp restore_key(nil), do: Application.delete_env(:comms_core, :governance_history_cursor_key)
  defp restore_key(key), do: Application.put_env(:comms_core, :governance_history_cursor_key, key)
end
