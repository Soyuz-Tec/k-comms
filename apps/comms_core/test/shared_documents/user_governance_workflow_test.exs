defmodule CommsCore.SharedDocuments.UserGovernanceWorkflowTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations, Governance, Repo, RuntimePorts, SharedDocuments}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Conversations.Membership
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.SharedDocuments.{Document, Operation}
  alias CommsTestSupport.Fixtures
  import Ecto.Query

  test "registered user deletion erases original tombstones and copied lineage before anonymizing identity" do
    context = lineage_fixture()
    retained = retained_documents(context)
    operation_count = operation_count(context.ids)
    assert operation_count >= 9
    install_identity_order_guard(context.member.id, context.ids)
    approved = approved_user_request(context)
    worker = RuntimePorts.job_worker!(:deletion)

    assert :ok = worker.perform(%Oban.Job{args: %{"deletion_request_id" => approved.id}})
    completed = Repo.get!(DeletionRequest, approved.id)
    assert completed.status == :completed
    assert completed.evidence["shared_document_erasure_version"] == 1
    assert completed.evidence["shared_documents_erased"] == 3
    assert completed.evidence["shared_document_operations_deleted"] == operation_count
    assert_erased(context)
    assert Repo.query!("SELECT count(*) FROM document_identity_order_proof").rows == [[1]]
    assert_retained(retained)

    # The persisted fence remains even when the registered worker receives delivery again.
    assert {:discard, :not_claimable} =
             worker.perform(%Oban.Job{args: %{"deletion_request_id" => approved.id}})

    assert operation_count(context.ids) == 0
    assert Enum.all?(context.ids, &Repo.get!(Document, &1).erased_at)
  end

  test "a hold on an original coauthor prevents false user completion and is retryable after release" do
    context = lineage_fixture()
    hold = coauthor_hold(context)
    documents = Enum.map(context.ids, &Repo.get!(Document, &1))
    operation_count = operation_count(context.ids)
    approved = approved_user_request(context)
    worker = RuntimePorts.job_worker!(:deletion)

    assert {:snooze, 300} =
             worker.perform(%Oban.Job{args: %{"deletion_request_id" => approved.id}})

    blocked = Repo.get!(DeletionRequest, approved.id)
    refute blocked.status == :completed
    refute blocked.evidence["shared_document_erasure_version"] == 1
    assert Repo.get!(User, context.member.id).external_subject == context.member.external_subject
    assert Repo.get!(User, context.member.id).status == :active
    refute Repo.get!(Session, context.member_subject.session_id).revoked_at
    assert Enum.map(context.ids, &Repo.get!(Document, &1)) == documents
    assert operation_count(context.ids) == operation_count

    release_hold(hold, context)
    assert :ok = worker.perform(%Oban.Job{args: %{"deletion_request_id" => approved.id}})

    assert Repo.get!(DeletionRequest, approved.id).evidence["shared_document_erasure_version"] ==
             1

    assert_erased(context)
  end

  test "registered historical user repair preserves old evidence and cannot certify held copied lineage" do
    context = lineage_fixture()
    hold = coauthor_hold(context)
    retained = retained_documents(context)
    approved = approved_user_request(context)

    Repo.get!(DeletionRequest, approved.id)
    |> DeletionRequest.changeset(%{
      status: :completed,
      completed_at: DateTime.utc_now(),
      evidence: %{
        "derived_erasure_version" => 1,
        "media_erasure_version" => 1,
        "meeting_erasure_version" => 1,
        "writer_fence_erasure_version" => 1,
        "historical_observation" => "preserve-original-user-evidence"
      }
    })
    |> Repo.update!()

    reconciler = RuntimePorts.job_worker!(:erasure_reconciler)
    assert {:ok, %{repaired: 0}} = Governance.reconcile_completed_erasure(reconciler, 100)
    blocked = Repo.get!(DeletionRequest, approved.id)
    refute blocked.evidence["shared_document_erasure_version"] == 1
    assert blocked.evidence["historical_observation"] == "preserve-original-user-evidence"
    assert Enum.all?(context.ids, &is_nil(Repo.get!(Document, &1).erased_at))
    assert Repo.get!(User, context.member.id).external_subject == context.member.external_subject
    refute Repo.get!(Session, context.member_subject.session_id).revoked_at

    release_hold(hold, context)
    install_identity_order_guard(context.member.id, context.ids)
    assert {:ok, %{repaired: 1}} = Governance.reconcile_completed_erasure(reconciler, 100)
    completed = Repo.get!(DeletionRequest, approved.id)
    assert completed.evidence["shared_document_erasure_version"] == 1
    assert completed.evidence["shared_documents_erased"] == 3
    assert completed.evidence["historical_observation"] == "preserve-original-user-evidence"
    assert_erased(context)
    assert Repo.query!("SELECT count(*) FROM document_identity_order_proof").rows == [[1]]
    assert_retained(retained)
    assert {:ok, %{repaired: 0}} = Governance.reconcile_completed_erasure(reconciler, 100)
  end

  defp lineage_fixture do
    account = Fixtures.account_fixture()
    owner = Fixtures.step_up(account)
    %{user: member} = Fixtures.user_fixture(account)
    suffix = member.email |> String.split(["member-", "@example.test"]) |> Enum.at(1)

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.email,
        "correct-horse-battery-#{suffix}",
        %{
          name: "Original author browser",
          platform: "test"
        }
      )

    member_subject = %{
      tenant_id: account.tenant.id,
      user_id: member.id,
      session_id: authentication.session_id,
      device_id: authentication.device.id,
      role: :member
    }

    {:ok, _} = Conversations.add_member_view(account.conversation.id, member.id, :member, owner)
    document = create_document(account, member_subject, "Original author's private title")
    apply_edit(document, member_subject, nil, [], "Original private 🌍\r\nline")
    {:ok, original} = SharedDocuments.get(document.id, member_subject)
    apply_edit(original, member_subject, nil, Enum.map(original.atoms, & &1.id), "")
    {:ok, tombstoned} = SharedDocuments.get(document.id, owner)
    assert tombstoned.content == ""
    assert Enum.all?(tombstoned.atoms, & &1.deleted)
    apply_edit(tombstoned, owner, nil, [], "Coauthor replacement")
    {:ok, replaced} = SharedDocuments.get(document.id, owner)
    rename(replaced, owner, "Coauthor title replacing the original")

    {:ok, copy} =
      SharedDocuments.copy(
        document.id,
        %{client_document_id: Ecto.UUID.generate(), title: "First private copy"},
        owner
      )

    rename(copy, owner, "Coauthor renamed first copy")

    {:ok, second_copy} =
      SharedDocuments.copy(
        copy.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Copy of a copy"},
        owner
      )

    apply_edit(
      second_copy,
      owner,
      List.last(second_copy.atoms).id,
      [],
      " plus later coauthor text"
    )

    ids = [document.id, copy.id, second_copy.id]

    for id <- ids do
      row = Repo.get!(Document, id)
      assert member.id in row.author_user_ids
      assert account.user.id in row.author_user_ids
    end

    %{account: account, owner: owner, member: member, member_subject: member_subject, ids: ids}
  end

  defp retained_documents(context) do
    same = create_document(context.account, context.owner, "Unrelated same-tenant document")
    apply_edit(same, context.owner, nil, [], "Unrelated same-tenant content")
    foreign = Fixtures.account_fixture()
    foreign_subject = Fixtures.subject(foreign)
    other = create_document(foreign, foreign_subject, "Unrelated foreign-tenant document")
    apply_edit(other, foreign_subject, nil, [], "Unrelated foreign-tenant content")

    Enum.map([same.id, other.id], fn id ->
      {Repo.get!(Document, id),
       Repo.all(from(op in Operation, where: op.document_id == ^id, order_by: op.version))}
    end)
  end

  defp assert_retained(retained) do
    for {document, operations} <- retained do
      assert Repo.get!(Document, document.id) == document

      assert Repo.all(
               from(op in Operation, where: op.document_id == ^document.id, order_by: op.version)
             ) == operations
    end
  end

  defp assert_erased(context) do
    for id <- context.ids do
      document = Repo.get!(Document, id)
      assert document.erased_at
      assert document.title == "Erased document"
      assert document.content == ""
      assert document.atoms == []
      assert document.author_user_ids == []
      assert document.created_by_user_id == nil
      assert document.created_by_device_id == nil
      assert document.retained_operation_bytes == 0
      assert document.generation == 2
      assert document.client_document_id
    end

    assert operation_count(context.ids) == 0
    erased_user = Repo.get!(User, context.member.id)
    assert erased_user.status == :deleted
    assert erased_user.display_name == "Deleted user"
    assert erased_user.external_subject == "deleted-#{context.member.id}"
    assert erased_user.email == "deleted-#{context.member.id}@invalid.example"
    assert Repo.get!(Session, context.member_subject.session_id).revoked_at

    assert Repo.get_by!(Membership,
             conversation_id: context.account.conversation.id,
             user_id: context.member.id
           ).left_at
  end

  defp create_document(account, subject, title) do
    {:ok, document} =
      SharedDocuments.create(
        account.conversation.id,
        %{client_document_id: Ecto.UUID.generate(), title: title},
        subject
      )

    document
  end

  defp apply_edit(document, subject, anchor, delete_ids, text) do
    assert {:ok, _, :created} =
             SharedDocuments.apply_operation(
               document.id,
               %{
                 client_operation_id: Ecto.UUID.generate(),
                 generation: document.generation,
                 base_version: document.version,
                 kind: "edit",
                 changes: [%{"after_id" => anchor, "delete_ids" => delete_ids, "insert" => text}]
               },
               subject
             )
  end

  defp rename(document, subject, title) do
    assert {:ok, _, :created} =
             SharedDocuments.apply_operation(
               document.id,
               %{
                 client_operation_id: Ecto.UUID.generate(),
                 generation: document.generation,
                 base_version: document.version,
                 kind: "rename",
                 title: title
               },
               subject
             )
  end

  defp approved_user_request(context) do
    {:ok, created} =
      Governance.create_deletion_request_view(
        %{
          target_type: "user",
          subject_user_id: context.member.id,
          reason: "Authorized original-author document erasure"
        },
        context.owner
      )

    {:ok, approved} =
      Governance.transition_deletion_request_view(
        created.request.id,
        %{
          version: created.request.version,
          status: "approved",
          transition_reason: "Verified synthetic user request"
        },
        context.owner
      )

    approved
  end

  defp coauthor_hold(context) do
    {:ok, %{hold: hold}} =
      Governance.create_legal_hold_view(
        %{
          name: "Original coauthor hold",
          reason: "Preserve original coauthor evidence",
          scope_type: "user",
          subject_user_id: context.account.user.id
        },
        context.owner
      )

    hold
  end

  defp release_hold(hold, context) do
    assert {:ok, %{status: :released}} =
             Governance.release_legal_hold_view(
               hold.id,
               %{
                 version: hold.version,
                 release_reason: "Synthetic coauthor investigation closed"
               },
               context.owner
             )
  end

  defp operation_count(ids),
    do: Repo.aggregate(from(op in Operation, where: op.document_id in ^ids), :count)

  defp install_identity_order_guard(user_id, ids) do
    # A real database trigger observes the exact unique-key update, rather than inferring
    # its order from the final state. All DDL and proof rows roll back with the sandbox.
    Repo.query!("CREATE TEMP TABLE document_identity_order_proof (user_id uuid) ON COMMIT DROP")

    Repo.query!("""
    CREATE FUNCTION pg_temp.document_identity_order_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE document_ids uuid[] := string_to_array(TG_ARGV[1], ',')::uuid[];
    BEGIN
      IF OLD.id::text = TG_ARGV[0] AND
        (NEW.external_subject IS DISTINCT FROM OLD.external_subject OR NEW.email IS DISTINCT FROM OLD.email) THEN
        IF (SELECT count(*) FROM shared_documents WHERE id = ANY(document_ids)) <> cardinality(document_ids)
          OR EXISTS (SELECT 1 FROM shared_documents WHERE id = ANY(document_ids) AND
            (erased_at IS NULL OR title <> 'Erased document' OR content <> '' OR
             cardinality(atoms) <> 0 OR cardinality(author_user_ids) <> 0 OR
             created_by_user_id IS NOT NULL OR created_by_device_id IS NOT NULL OR retained_operation_bytes <> 0))
          OR EXISTS (SELECT 1 FROM shared_document_operations WHERE document_id = ANY(document_ids))
          OR EXISTS (SELECT 1 FROM sessions WHERE user_id = OLD.id AND revoked_at IS NULL) THEN
          RAISE EXCEPTION 'identity unique keys updated before document and session erasure';
        END IF;
        INSERT INTO document_identity_order_proof VALUES (OLD.id);
      END IF;
      RETURN NEW;
    END $$
    """)

    # Both interpolated arguments are fixture-generated UUIDs, never user input.
    assert Enum.all?([user_id | ids], &match?({:ok, _}, Ecto.UUID.cast(&1)))

    Repo.query!("""
    CREATE TRIGGER document_identity_order_guard BEFORE UPDATE OF external_subject, email ON users
    FOR EACH ROW EXECUTE FUNCTION pg_temp.document_identity_order_guard('#{user_id}', '#{Enum.join(ids, ",")}')
    """)
  end
end
