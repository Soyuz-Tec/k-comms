defmodule CommsCore.AuthorizationDatabaseTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{Device, Session, Tenant, User}
  alias CommsCore.Authorization
  alias CommsCore.Conversations.Membership
  alias CommsCore.Messaging
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "authorization rejects inactive tenant, user, device, or session" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    resource = %{id: account.conversation.id}
    now = now()

    assert :ok = Authorization.authorize(:send_message, subject, resource)

    account.session |> Session.changeset(%{revoked_at: now}) |> Repo.update!()
    assert {:error, :forbidden} = Authorization.authorize(:send_message, subject, resource)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.device |> Device.changeset(%{revoked_at: now}) |> Repo.update!()
    assert {:error, :forbidden} = Authorization.authorize(:send_message, subject, resource)
    Repo.get!(Device, account.device.id) |> Device.changeset(%{revoked_at: nil}) |> Repo.update!()

    account.user |> User.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Authorization.authorize(:send_message, subject, resource)
    Repo.get!(User, account.user.id) |> User.changeset(%{status: :active}) |> Repo.update!()

    account.tenant |> Tenant.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Authorization.authorize(:send_message, subject, resource)
  end

  test "revocation and membership removal deny every conversation command" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    conversation = account.conversation

    attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: "authorization-message-1",
      body: "authorized before revocation"
    }

    assert {:ok, message} = Messaging.accept_message(attrs, subject)
    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)

    for {action, resource} <- [
          {:read_conversation, %{id: conversation.id}},
          {:send_message, conversation},
          {:mark_read, %{id: conversation.id}},
          {:manage_conversation, %{id: conversation.id}},
          {:edit_message, message},
          {:delete_message, message},
          {:administer_tenant, %{id: account.tenant.id}}
        ] do
      assert {:error, :forbidden} = Authorization.authorize(action, subject, resource)
    end

    assert {:error, :forbidden} = Messaging.accept_message(attrs, subject)

    fresh = Fixtures.account_fixture()
    fresh_subject = Fixtures.subject(fresh)

    membership =
      Repo.get_by!(Membership,
        conversation_id: fresh.conversation.id,
        user_id: fresh.user.id
      )

    membership |> Membership.changeset(%{left_at: now()}) |> Repo.update!()

    assert {:error, :forbidden} =
             Authorization.authorize(:send_message, fresh_subject, fresh.conversation)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
