defmodule CommsCore.SharedDocuments.GovernanceWorkflowTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Governance, Repo, RuntimePorts, SharedDocuments}
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.SharedDocuments.{Document, Operation}
  alias CommsTestSupport.Fixtures
  import Ecto.Query

  test "the actual registered deletion worker fences live access and supplies document erasure proof" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    {:ok, document} =
      SharedDocuments.create(
        account.conversation.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Private authored title"},
        subject
      )

    {:ok, _, :created} =
      SharedDocuments.apply_operation(
        document.id,
        %{
          client_operation_id: Ecto.UUID.generate(),
          generation: 1,
          base_version: 1,
          kind: "edit",
          changes: [
            %{"after_id" => nil, "delete_ids" => [], "insert" => "Private authored phrase"}
          ]
        },
        subject
      )

    foreign = Fixtures.account_fixture()

    {:ok, untouched} =
      SharedDocuments.create(
        foreign.conversation.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Foreign document"},
        Fixtures.subject(foreign)
      )

    approved = approved_request(account, subject)
    assert {:error, :forbidden} = SharedDocuments.get(document.id, subject)
    assert {:error, :forbidden} = SharedDocuments.export(document.id, subject)
    assert {:error, :forbidden} = SharedDocuments.replay(document.id, 1, 0, 100, subject)
    worker = RuntimePorts.job_worker!(:deletion)
    assert :ok = worker.perform(%Oban.Job{args: %{"deletion_request_id" => approved.id}})
    completed = Repo.get!(DeletionRequest, approved.id)
    assert completed.status == :completed
    assert completed.evidence["shared_document_erasure_version"] == 1
    assert completed.evidence["shared_documents_erased"] == 1
    assert completed.evidence["shared_document_operations_deleted"] == 2
    erased = Repo.get!(Document, document.id)
    assert erased.erased_at && erased.content == "" && erased.atoms == []
    refute Repo.exists?(from(op in Operation, where: op.document_id == ^document.id))
    assert Repo.get!(Document, untouched.id).title == "Foreign document"
  end

  test "historical completed requests without document proof are repaired through the actual registered reconciliation owner" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    {:ok, document} =
      SharedDocuments.create(
        account.conversation.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Previously retained title"},
        subject
      )

    approved = approved_request(account, subject)

    evidence = %{
      "derived_erasure_version" => 1,
      "media_erasure_version" => 1,
      "meeting_erasure_version" => 1,
      "writer_fence_erasure_version" => 1,
      "historical_observation" => "preserve-original-evidence"
    }

    approved
    |> DeletionRequest.changeset(%{
      status: :completed,
      completed_at: DateTime.utc_now(),
      evidence: evidence
    })
    |> Repo.update!()

    reconciler = RuntimePorts.job_worker!(:erasure_reconciler)
    assert {:ok, %{repaired: 1}} = Governance.reconcile_completed_erasure(reconciler, 100)
    completed = Repo.get!(DeletionRequest, approved.id)
    assert completed.evidence["shared_document_erasure_version"] == 1
    assert completed.evidence["historical_observation"] == "preserve-original-evidence"
    assert Repo.get!(Document, document.id).erased_at
    refute Repo.exists?(from(op in Operation, where: op.document_id == ^document.id))
  end

  defp approved_request(account, subject) do
    {:ok, created} =
      Governance.create_deletion_request(
        %{
          target_type: :conversation,
          conversation_id: account.conversation.id,
          reason: "Authorized synthetic document erasure"
        },
        subject
      )

    {:ok, approved} =
      Governance.transition_deletion_request(
        created.request.id,
        %{
          version: created.request.lock_version,
          status: "approved",
          transition_reason: "Verified synthetic request"
        },
        subject
      )

    approved
  end
end
