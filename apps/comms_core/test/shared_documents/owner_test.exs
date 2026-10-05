defmodule CommsCore.SharedDocuments.OwnerTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo, SharedDocuments}
  alias CommsCore.Governance.{LegalHold, TenantLock}
  alias CommsCore.SharedDocuments.{Document, Operation}
  alias CommsTestSupport.Fixtures

  test "two current devices converge, replay exact receipts and reject foreign idempotency reuse" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    suffix = account.tenant.slug |> String.split("-") |> List.last()

    {:ok, other} =
      Accounts.authenticate_view(
        account.tenant.slug,
        account.user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Other document editor", platform: "test"}
      )

    other_subject = %{subject | session_id: other.session_id, device_id: other.device.id}
    {:ok, document} = create(account, subject)
    first = edit(document, nil, [], "A")

    assert {:ok, operation, :created} =
             SharedDocuments.apply_operation(document.id, first, subject)

    assert {:ok, ^operation, :duplicate} =
             SharedDocuments.apply_operation(document.id, first, subject)

    assert {:error, :idempotency_conflict} =
             SharedDocuments.apply_operation(document.id, first, other_subject)

    stale = edit(document, nil, [], "B")

    assert {:ok, second, :created} =
             SharedDocuments.apply_operation(document.id, stale, other_subject)

    assert second.version == 3
    assert {:ok, current} = SharedDocuments.get(document.id, subject)
    assert current.content == "BA"

    assert {:ok, %{operations: [created, ^operation], has_more: true, next_after_version: 2}} =
             SharedDocuments.replay(document.id, 1, 0, 2, other_subject)

    assert created.kind == "create"

    assert {:ok, %{operations: [^second], has_more: false}} =
             SharedDocuments.replay(document.id, 1, 2, 2, subject)
  end

  test "title CAS, server-owned provenance and copy lineage cannot be rewritten by clients" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, document} = create(account, subject)
    request = edit(document, nil, [], "private phrase") |> Map.put(:author_user_ids, [])
    assert {:ok, _, :created} = SharedDocuments.apply_operation(document.id, request, subject)

    assert {:error, :stale_version} =
             SharedDocuments.apply_operation(document.id, rename(document, "Stale"), subject)

    assert {:ok, current} = SharedDocuments.get(document.id, subject)

    assert {:ok, _, :created} =
             SharedDocuments.apply_operation(document.id, rename(current, "New title"), subject)

    assert {:ok, copy} =
             SharedDocuments.copy(
               document.id,
               %{client_document_id: Ecto.UUID.generate(), title: "Derived copy"},
               subject
             )

    assert copy.content == "private phrase"
    assert Repo.get!(Document, copy.id).author_user_ids == [account.user.id]
    assert Enum.all?(copy.atoms, &(!String.starts_with?(&1.id, request.client_operation_id)))
  end

  test "governed author erasure removes copies, operation inputs and tombstones while unrelated documents survive" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    member = member_subject(account)
    {:ok, own} = create(account, subject)

    assert {:ok, _, :created} =
             SharedDocuments.apply_operation(
               own.id,
               edit(own, nil, [], "original private text"),
               subject
             )

    {:ok, current} = SharedDocuments.get(own.id, subject)

    assert {:ok, _, :created} =
             SharedDocuments.apply_operation(
               own.id,
               edit(current, nil, Enum.map(current.atoms, & &1.id), "replacement"),
               member
             )

    {:ok, copy} =
      SharedDocuments.copy(
        own.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Copy"},
        member
      )

    {:ok, unrelated} = create(account, member)

    assert {:ok, _, :created} =
             SharedDocuments.apply_operation(
               unrelated.id,
               edit(unrelated, nil, [], "survives"),
               member
             )

    foreign = Fixtures.account_fixture()
    {:ok, foreign_document} = create(foreign, Fixtures.subject(foreign))

    assert {:ok, {:ok, %{documents_erased: 2}}} =
             Repo.transaction(fn ->
               TenantLock.lock!(account.tenant.id)

               SharedDocuments.erase_for_governance(
                 account.tenant.id,
                 :user,
                 account.user.id,
                 DateTime.utc_now()
               )
             end)

    for id <- [own.id, copy.id] do
      erased = Repo.get!(Document, id)
      assert erased.content == "" and erased.atoms == [] and erased.author_user_ids == []
      assert erased.generation == 2 and erased.erased_at
      refute Repo.exists?(from(op in Operation, where: op.document_id == ^id))
      assert {:error, :not_found} = SharedDocuments.get(id, member)

      assert {:error, :not_found} =
               SharedDocuments.apply_operation(
                 id,
                 edit(own, nil, [], "replay cannot revive"),
                 member
               )
    end

    assert {:ok, %{content: "survives"}} = SharedDocuments.get(unrelated.id, member)
    assert Repo.get!(Document, foreign_document.id)
  end

  test "holds and unknown original-author lineage prevent a false erasure receipt" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, document} = create(account, subject)

    {:ok, _} =
      %LegalHold{}
      |> LegalHold.changeset(%{
        tenant_id: account.tenant.id,
        name: "Document hold",
        reason: "Preserve evidence",
        scope_type: :conversation,
        conversation_id: account.conversation.id,
        status: :active,
        starts_at: DateTime.utc_now(),
        created_by_user_id: account.user.id
      })
      |> Repo.insert()

    assert {:error, :legal_hold_active} =
             Repo.transaction(fn ->
               TenantLock.lock!(account.tenant.id)

               SharedDocuments.erase_for_governance(
                 account.tenant.id,
                 :user,
                 account.user.id,
                 DateTime.utc_now()
               )
             end)

    assert Repo.get!(Document, document.id).erased_at == nil
    Repo.delete_all(LegalHold)

    Repo.get!(Document, document.id)
    |> Ecto.Changeset.change(lineage_verified: false)
    |> Repo.update!()

    assert {:error, :document_lineage_unknown} =
             Repo.transaction(fn ->
               TenantLock.lock!(account.tenant.id)

               SharedDocuments.erase_for_governance(
                 account.tenant.id,
                 :user,
                 account.user.id,
                 DateTime.utc_now()
               )
             end)

    assert {:error, :document_lineage_unknown} = SharedDocuments.get(document.id, subject)
  end

  test "current session, membership, tenant isolation and conversation-only restrictions cover all disclosures" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, document} = create(account, subject)
    foreign = Fixtures.account_fixture() |> Fixtures.subject()
    assert {:error, :not_found} = SharedDocuments.get(document.id, foreign)
    assert {:error, :forbidden} = SharedDocuments.list(account.conversation.id, "", foreign)
    account.user |> Ecto.Changeset.change(access_scope: :conversation_only) |> Repo.update!()
    assert {:error, :forbidden} = SharedDocuments.get(document.id, subject)
    account.user |> Ecto.Changeset.change(access_scope: :workspace) |> Repo.update!()
    assert :ok = Accounts.revoke_session(account.session.id, subject)

    for function <- [
          fn -> SharedDocuments.get(document.id, subject) end,
          fn -> SharedDocuments.export(document.id, subject) end,
          fn -> SharedDocuments.replay(document.id, 1, 0, 100, subject) end,
          fn ->
            SharedDocuments.apply_operation(document.id, edit(document, nil, [], "late"), subject)
          end
        ] do
      assert {:error, :forbidden} = function.()
    end
  end

  test "search summaries cannot disclose atom history and operation exhaustion never erases provenance" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, document} = create(account, subject)

    assert {:ok, _, :created} =
             SharedDocuments.apply_operation(
               document.id,
               edit(document, nil, [], "find this phrase"),
               subject
             )

    assert {:ok, [summary]} = SharedDocuments.list(account.conversation.id, "phrase", subject)
    refute Map.has_key?(Map.from_struct(summary), :atoms)
    refute Map.has_key?(Map.from_struct(summary), :content)
    Repo.get!(Document, document.id) |> Ecto.Changeset.change(version: 4_000) |> Repo.update!()

    assert {:error, :document_capacity_exceeded} =
             SharedDocuments.apply_operation(
               document.id,
               edit(document, nil, [], "late"),
               subject
             )

    assert {:ok, %{readonly: true, content: "find this phrase"}} =
             SharedDocuments.get(document.id, subject)

    assert Repo.get!(Document, document.id).author_user_ids == [account.user.id]
  end

  test "creation and copying return the persisted accounting receipt, and byte exhaustion fails atomically" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, document} = create(account, subject)
    stored = Repo.get!(Document, document.id)
    assert stored.retained_operation_bytes > 512
    assert document.updated_at == stored.updated_at

    {:ok, copied} =
      SharedDocuments.copy(
        document.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Copy receipt"},
        subject
      )

    stored_copy = Repo.get!(Document, copied.id)
    assert stored_copy.retained_operation_bytes > 512
    assert copied.updated_at == stored_copy.updated_at
    stored |> Ecto.Changeset.change(retained_operation_bytes: 16_777_210) |> Repo.update!()

    operation_count =
      Repo.aggregate(from(op in Operation, where: op.document_id == ^document.id), :count)

    assert {:error, :document_capacity_exceeded} =
             SharedDocuments.apply_operation(
               document.id,
               edit(document, nil, [], "must not partially commit"),
               subject
             )

    retained = Repo.get!(Document, document.id)
    assert retained.content == "" and retained.atoms == [] and retained.version == 1
    assert retained.retained_operation_bytes == 16_777_210
    assert {:ok, %{readonly: true}} = SharedDocuments.get(document.id, subject)
    assert retained.author_user_ids == [account.user.id]

    assert Repo.aggregate(from(op in Operation, where: op.document_id == ^document.id), :count) ==
             operation_count

    assert {:ok, {:ok, %{documents_erased: 2}}} =
             Repo.transaction(fn ->
               SharedDocuments.erase_for_governance(
                 account.tenant.id,
                 :conversation,
                 account.conversation.id,
                 DateTime.utc_now()
               )
             end)

    assert Repo.get!(Document, document.id).retained_operation_bytes == 0
  end

  test "rollback inventory includes erased generation fences and fingerprint fragments are tenant-bound IDs" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert SharedDocuments.rollback_hazard_count() == 0
    {:ok, document} = create(account, subject)
    assert SharedDocuments.rollback_hazard_count() == 2

    assert %{shared_documents: [id], shared_document_operations: [operation_id]} =
             SharedDocuments.release_tenant_fingerprint_fragment(Repo, account.tenant.id)

    assert id == document.id and is_binary(operation_id)

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               TenantLock.lock!(account.tenant.id)

               SharedDocuments.erase_for_governance(
                 account.tenant.id,
                 :conversation,
                 account.conversation.id,
                 DateTime.utc_now()
               )
             end)

    assert SharedDocuments.rollback_hazard_count() == 1

    assert %{shared_documents: [], shared_document_operations: []} =
             SharedDocuments.release_tenant_fingerprint_fragment(Repo, Ecto.UUID.generate())
  end

  defp create(account, subject),
    do:
      SharedDocuments.create(
        account.conversation.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Notes"},
        subject
      )

  defp edit(document, anchor, ids, text),
    do: %{
      client_operation_id: Ecto.UUID.generate(),
      generation: document.generation,
      base_version: document.version,
      kind: "edit",
      changes: [%{"after_id" => anchor, "delete_ids" => ids, "insert" => text}]
    }

  defp rename(document, title),
    do: %{
      client_operation_id: Ecto.UUID.generate(),
      generation: document.generation,
      base_version: document.version,
      kind: "rename",
      title: title
    }

  defp member_subject(account) do
    %{user: user} = Fixtures.user_fixture(account)
    suffix = user.email |> String.split(["member-", "@example.test"]) |> Enum.at(1)

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Member document browser", platform: "test"}
      )

    subject = %{
      tenant_id: account.tenant.id,
      user_id: user.id,
      session_id: authentication.session_id,
      device_id: authentication.device.id,
      role: :member
    }

    assert {:ok, _} =
             Conversations.add_member_view(
               account.conversation.id,
               user.id,
               :member,
               Fixtures.subject(account)
             )

    subject
  end
end
