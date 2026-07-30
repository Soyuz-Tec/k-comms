defmodule CommsCore.Accounts.BootstrapTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Administration, Audit, Repo}

  alias CommsCore.Accounts.{
    ConversationBootstrapPort,
    InitialConversationCommand,
    InitialConversationReceipt,
    Session,
    User
  }

  alias CommsCore.Administration.{Tenant, TenantView}
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Security.Password

  @moduletag :integration

  test "bootstrap returns foreign owner views instead of persistence structs" do
    suffix = System.unique_integer([:positive, :monotonic])

    assert {:ok, result} =
             Accounts.bootstrap_tenant(%{
               tenant_name: "Boundary #{suffix}",
               tenant_slug: "boundary-#{suffix}",
               display_name: "Boundary Owner",
               email: "boundary-#{suffix}@example.test",
               password: "correct-horse-boundary-#{suffix}",
               device_name: "Boundary browser",
               device_platform: "test"
             })

    assert %TenantView{} = result.tenant
    assert %InitialConversationReceipt{} = result.conversation
  end

  test "owner-contributed bootstrap writes roll back after a later failure" do
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()

    result =
      Ecto.Multi.new()
      |> Administration.append_bootstrap_tenant(:tenant, %{
        id: tenant_id,
        name: "Rollback tenant",
        slug: "rollback-#{System.unique_integer([:positive, :monotonic])}"
      })
      |> Ecto.Multi.insert(
        :user,
        User.changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: "local:rollback@example.test",
          display_name: "Rollback owner",
          email: "rollback-#{user_id}@example.test",
          password_hash: Password.hash("correct-horse-rollback"),
          account_type: :human,
          role: :owner,
          status: :active
        })
      )
      |> ConversationBootstrapPort.append_initial_channel(
        :conversation,
        %InitialConversationCommand{
          id: conversation_id,
          tenant_id: tenant_id,
          owner_user_id: user_id,
          joined_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }
      )
      |> Ecto.Multi.run(:forced_failure, fn _repo, _changes ->
        {:error, :forced_failure}
      end)
      |> Repo.transaction()

    assert {:error, :forced_failure, :forced_failure, _changes} = result
    refute Repo.get(Tenant, tenant_id)
    refute Repo.get(User, user_id)
    refute Repo.get(Conversation, conversation_id)
    refute Repo.get_by(Membership, conversation_id: conversation_id)
  end

  test "one-time release bootstrap is sessionless and idempotent" do
    attrs = release_bootstrap_attrs()

    assert {:ok, created} = Accounts.bootstrap_tenant_once(attrs)
    assert created.status == :created
    assert created.tenant.slug == attrs.tenant_slug
    assert created.user.email == attrs.email
    assert created.user.role == :owner
    assert created.conversation.title == "General"

    assert Repo.aggregate(Tenant, :count) == 1
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(Conversation, :count) == 1
    assert Repo.aggregate(Membership, :count) == 1
    assert Audit.count(%{tenant_id: created.tenant.id}) == 1
    assert Repo.aggregate(Session, :count) == 0

    assert {:ok, existing} = Accounts.bootstrap_tenant_once(attrs)
    assert existing.status == :existing
    assert existing.tenant.id == created.tenant.id
    assert existing.user.id == created.user.id
    assert existing.conversation.id == created.conversation.id

    assert Repo.aggregate(Tenant, :count) == 1
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(Conversation, :count) == 1
    assert Repo.aggregate(Membership, :count) == 1
    assert Audit.count(%{tenant_id: created.tenant.id}) == 1
    assert Repo.aggregate(Session, :count) == 0

    assert {:ok, authenticated} =
             Accounts.authenticate_view(attrs.tenant_slug, attrs.email, attrs.password)

    assert authenticated.user.id == created.user.id
  end

  test "one-time release bootstrap rejects a different identity" do
    attrs = release_bootstrap_attrs()
    assert {:ok, %{status: :created}} = Accounts.bootstrap_tenant_once(attrs)

    assert {:error, :bootstrap_identity_conflict} =
             Accounts.bootstrap_tenant_once(%{
               attrs
               | tenant_slug: "another-workspace",
                 email: "another-owner@example.test"
             })

    assert {:error, :bootstrap_identity_conflict} =
             Accounts.bootstrap_tenant_once(%{attrs | email: "another-owner@example.test"})

    assert Repo.aggregate(Tenant, :count) == 1
    assert Repo.aggregate(User, :count) == 1
  end

  test "release qualification tenant deletion is exact, cascading, and idempotent" do
    qualification_id = String.duplicate("b", 32)

    attrs = %{
      tenant_name: "K-Comms qualification #{qualification_id}",
      tenant_slug: "k-comms-qualification-#{qualification_id}",
      display_name: "K-Comms Qualification Owner",
      email: "k-comms-qualification-owner+#{qualification_id}@example.test",
      password: String.duplicate("Qx9!", 12)
    }

    assert {:ok, created} = Accounts.bootstrap_tenant(attrs)
    assert Repo.get(Tenant, created.tenant.id)
    assert Repo.get(User, created.user.id)
    assert Repo.get(Conversation, created.conversation.id)
    assert Repo.get(Session, created.session.id)

    assert {:error, :qualification_tenant_identity_conflict} =
             Accounts.delete_release_qualification_tenant(%{
               attrs
               | email: "other-owner@example.test"
             })

    assert Repo.get(Tenant, created.tenant.id)

    assert {:ok, %{status: :deleted, tenant: deleted}} =
             Accounts.delete_release_qualification_tenant(attrs)

    assert deleted.id == created.tenant.id
    refute Repo.get(Tenant, created.tenant.id)
    refute Repo.get(User, created.user.id)
    refute Repo.get(Conversation, created.conversation.id)
    refute Repo.get(Session, created.session.id)

    assert {:ok, %{status: :absent, tenant_slug: tenant_slug}} =
             Accounts.delete_release_qualification_tenant(attrs)

    assert tenant_slug == attrs.tenant_slug
  end

  defp release_bootstrap_attrs do
    %{
      tenant_name: "Staging Workspace",
      tenant_slug: "staging-workspace",
      display_name: "Staging Owner",
      email: "staging-owner@example.test",
      password: "correct-horse-staging-owner"
    }
  end
end
