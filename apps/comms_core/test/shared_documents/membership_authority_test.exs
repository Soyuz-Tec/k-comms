defmodule CommsCore.SharedDocuments.MembershipAuthorityTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations, Repo, SharedDocuments}
  alias CommsCore.SharedDocuments.{Document, Operation}
  alias CommsTestSupport.Fixtures
  import Ecto.Query

  test "public membership withdrawal denies reads, export, replay, new and duplicate edits, and copying" do
    account = Fixtures.account_fixture()
    owner = Fixtures.subject(account)
    %{user: member} = Fixtures.user_fixture(account)
    suffix = member.email |> String.split(["member-", "@example.test"]) |> Enum.at(1)

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Membership document browser", platform: "test"}
      )

    subject = %{
      tenant_id: account.tenant.id,
      user_id: member.id,
      session_id: authentication.session_id,
      device_id: authentication.device.id,
      role: :member
    }

    {:ok, membership} =
      Conversations.add_member_view(account.conversation.id, member.id, :member, owner)

    {:ok, document} =
      SharedDocuments.create(
        account.conversation.id,
        %{client_document_id: Ecto.UUID.generate(), title: "Withdrawn member's document"},
        subject
      )

    operation = %{
      client_operation_id: Ecto.UUID.generate(),
      generation: document.generation,
      base_version: document.version,
      kind: "edit",
      changes: [%{"after_id" => nil, "delete_ids" => [], "insert" => "Retained private text"}]
    }

    assert {:ok, _, :created} = SharedDocuments.apply_operation(document.id, operation, subject)
    assert {:ok, %{content: "Retained private text"}} = SharedDocuments.get(document.id, subject)
    assert {:ok, _} = SharedDocuments.export(document.id, subject)
    assert {:ok, _} = SharedDocuments.replay(document.id, document.generation, 0, 100, subject)
    assert {:ok, _, :duplicate} = SharedDocuments.apply_operation(document.id, operation, subject)

    before_document = Repo.get!(Document, document.id)

    operation_count =
      Repo.aggregate(from(op in Operation, where: op.document_id == ^document.id), :count)

    assert {:ok, %{left_at: %DateTime{}}} =
             Conversations.remove_member_view(
               account.conversation.id,
               member.id,
               %{version: membership.version},
               owner
             )

    assert {:error, :forbidden} = SharedDocuments.authorize(document.id, subject)
    assert {:error, :forbidden} = SharedDocuments.get(document.id, subject)
    assert {:error, :forbidden} = SharedDocuments.export(document.id, subject)

    assert {:error, :forbidden} =
             SharedDocuments.replay(document.id, document.generation, 0, 100, subject)

    assert {:error, :forbidden} = SharedDocuments.apply_operation(document.id, operation, subject)

    assert {:error, :forbidden} =
             SharedDocuments.apply_operation(
               document.id,
               %{operation | client_operation_id: Ecto.UUID.generate()},
               subject
             )

    copy_id = Ecto.UUID.generate()

    assert {:error, :forbidden} =
             SharedDocuments.copy(
               document.id,
               %{client_document_id: copy_id, title: "Denied copy"},
               subject
             )

    assert Repo.get!(Document, document.id) == before_document

    assert Repo.aggregate(from(op in Operation, where: op.document_id == ^document.id), :count) ==
             operation_count

    refute Repo.exists?(from(doc in Document, where: doc.client_document_id == ^copy_id))
    assert {:ok, %{content: "Retained private text"}} = SharedDocuments.get(document.id, owner)
  end
end
