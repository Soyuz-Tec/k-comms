defmodule CommsCore.Conversations.AccessPolicyTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "owner-local authorization exposes id-only conversation contracts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    conversation_id = account.conversation.id

    assert :ok = Conversations.authorize_create(subject)
    assert :ok = Conversations.authorize_discovery(subject)
    assert :ok = Conversations.authorize_join(conversation_id, subject)
    assert :ok = Conversations.authorize_leave(conversation_id, subject)
    assert :ok = Conversations.authorize_read(conversation_id, subject)
    assert :ok = Conversations.authorize_send_message(conversation_id, subject)
    assert :ok = Conversations.authorize_mark_read(conversation_id, subject)
    assert :ok = Conversations.authorize_react_message(conversation_id, subject)
    assert :ok = Conversations.authorize_upload_attachment(conversation_id, subject)
    assert :ok = Conversations.authorize_manage(conversation_id, subject)
    assert :ok = Conversations.authorize_manage_ownership(conversation_id, subject)

    other_account = Fixtures.account_fixture()
    other_subject = Fixtures.subject(other_account)

    assert {:error, :forbidden} =
             Conversations.authorize_read(conversation_id, other_subject)

    assert {:error, :forbidden} =
             Conversations.authorize_manage(conversation_id, other_subject)
  end

  test "tenant administrators without membership cannot manage private conversations" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)

    assert {:ok, admin} =
             Accounts.create_user(
               %{
                 display_name: "Private Boundary Admin",
                 email: "private-boundary-admin@example.test",
                 password: "correct-horse-private-boundary",
                 role: "admin"
               },
               owner_subject
             )

    assert {:ok, login} =
             Accounts.authenticate_view(
               account.tenant.slug,
               admin.email,
               "correct-horse-private-boundary",
               %{name: "Admin browser", platform: "test"}
             )

    assert {:ok, %{subject: admin_subject}} = Accounts.access_context(login.session_id)

    assert {:ok, private_group} =
             Conversations.create(
               %{kind: "group", title: "Private group", visibility: "private"},
               owner_subject
             )

    assert {:error, :forbidden} =
             Conversations.update(
               private_group.id,
               %{version: private_group.lock_version, title: "Unauthorized"},
               admin_subject
             )
  end
end
