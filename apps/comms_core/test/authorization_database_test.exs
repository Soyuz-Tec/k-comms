defmodule CommsCore.OwnerAuthorizationTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Administration
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.AudioCalls.AuthorizationPolicy
  alias CommsCore.Conversations
  alias CommsCore.Conversations.Membership
  alias CommsCore.Messaging
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "authorization rejects inactive tenant, user, device, or session" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    conversation_id = account.conversation.id
    now = now()

    assert :ok = Conversations.authorize_send_message(conversation_id, subject)

    account.session |> Session.changeset(%{revoked_at: now}) |> Repo.update!()

    assert {:error, :forbidden} =
             Conversations.authorize_send_message(conversation_id, subject)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.device |> Device.changeset(%{revoked_at: now}) |> Repo.update!()

    assert {:error, :forbidden} =
             Conversations.authorize_send_message(conversation_id, subject)

    Repo.get!(Device, account.device.id) |> Device.changeset(%{revoked_at: nil}) |> Repo.update!()

    account.user |> User.changeset(%{status: :suspended}) |> Repo.update!()

    assert {:error, :forbidden} =
             Conversations.authorize_send_message(conversation_id, subject)

    Repo.get!(User, account.user.id) |> User.changeset(%{status: :active}) |> Repo.update!()

    account.tenant |> Tenant.changeset(%{status: :suspended}) |> Repo.update!()

    assert {:error, :forbidden} =
             Conversations.authorize_send_message(conversation_id, subject)
  end

  test "authorization rejects a session after its stored absolute deadline" do
    previous = Application.get_env(:comms_core, :session_absolute_ttl_seconds)

    on_exit(fn ->
      Application.put_env(:comms_core, :session_absolute_ttl_seconds, previous)
    end)

    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 0)

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert account.session.expires_at == account.session.absolute_expires_at

    assert {:error, :forbidden} =
             Conversations.authorize_send_message(account.conversation.id, subject)
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

    assert {:error, :forbidden} = Conversations.authorize_read(conversation.id, subject)

    assert {:error, :forbidden} =
             Conversations.authorize_send_message(conversation.id, subject)

    assert {:error, :forbidden} =
             Conversations.authorize_mark_read(conversation.id, subject)

    assert {:error, :forbidden} = Conversations.authorize_manage(conversation.id, subject)
    assert {:error, :forbidden} = Messaging.edit_message(message.id, "denied", subject)

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn ->
               Messaging.delete_message(message.id, subject, fn _candidate -> :ok end)
             end)

    assert {:error, :forbidden} = Administration.authorize_administer_tenant(subject)

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
             Conversations.authorize_send_message(fresh.conversation.id, fresh_subject)
  end

  test "Calls owner policy preserves resource and active-subject error precedence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    (Repo.get_by(TenantSettings, tenant_id: account.tenant.id) ||
       %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(%{
      allow_audio_calls: false,
      allow_video_calls: false
    })
    |> Repo.insert_or_update!()

    for action <- [:start_audio_call, :start_video_call] do
      assert {:error, :missing_conversation} =
               AuthorizationPolicy.authorize(action, subject, %{})
    end

    account.session |> Session.changeset(%{revoked_at: now()}) |> Repo.update!()

    for action <- [:start_audio_call, :start_video_call] do
      assert {:error, :forbidden} =
               AuthorizationPolicy.authorize(action, subject, %{id: account.conversation.id})
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
