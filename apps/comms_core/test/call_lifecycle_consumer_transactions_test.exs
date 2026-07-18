defmodule CommsCore.CallLifecycleConsumerTransactionsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Administration
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Accounts
  alias CommsCore.Accounts.Session
  alias CommsCore.Conversations
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  defmodule FailingIdentityAdapter do
    @behaviour CommsCore.Accounts.CallLifecyclePort

    @impl true
    def revoke_identity_access(%CommsCore.Accounts.CallLifecycleCommand{} = command) do
      send(
        self(),
        {:identity_call_lifecycle_contribution, CommsCore.Repo.in_transaction?(), command}
      )

      {:error, :forced_call_lifecycle_failure}
    end
  end

  defmodule FailingTenantAdapter do
    @behaviour CommsCore.Administration.CallLifecyclePort

    @impl true
    def revoke_tenant_media(%CommsCore.Administration.CallLifecycleCommand{} = command) do
      send(
        self(),
        {:tenant_call_lifecycle_contribution, CommsCore.Repo.in_transaction?(), command}
      )

      {:error, :forced_call_lifecycle_failure}
    end
  end

  defmodule FailingConversationAdapter do
    @behaviour CommsCore.Conversations.CallLifecyclePort

    @impl true
    def revoke_conversation_access(%CommsCore.Conversations.CallLifecycleCommand{} = command) do
      send(
        self(),
        {:conversation_call_lifecycle_contribution, CommsCore.Repo.in_transaction?(), command}
      )

      {:error, :forced_call_lifecycle_failure}
    end
  end

  test "session revocation rolls back when the Calls contribution fails" do
    account = Fixtures.account_fixture()
    session_id = account.session.id
    tenant_id = account.tenant.id

    replace_adapter(:identity_call_lifecycle_adapter, FailingIdentityAdapter)

    assert {:error, :forced_call_lifecycle_failure} =
             Accounts.revoke_session(session_id, account.user.id)

    assert_receive {:identity_call_lifecycle_contribution, true,
                    %CommsCore.Accounts.CallLifecycleCommand{
                      operation: :sessions_revoked,
                      tenant_id: ^tenant_id,
                      session_ids: [^session_id],
                      device_id: nil,
                      user_id: nil,
                      reason: "session_logout"
                    }}

    refute Repo.get!(Session, session_id).revoked_at
  end

  test "tenant capability changes roll back when the Calls contribution fails" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    tenant_id = account.tenant.id

    assert {:ok, %{settings: existing_settings}} =
             Administration.update_tenant_settings(
               %{version: 1, allow_public_channels: false},
               subject
             )

    replace_adapter(:tenant_call_lifecycle_adapter, FailingTenantAdapter)

    assert {:error, :forced_call_lifecycle_failure} =
             Administration.update_tenant_settings(
               %{version: existing_settings.lock_version, allow_audio_calls: false},
               subject
             )

    assert_receive {:tenant_call_lifecycle_contribution, true,
                    %CommsCore.Administration.CallLifecycleCommand{
                      operation: :tenant_media_disabled,
                      tenant_id: ^tenant_id,
                      media_kind: :audio,
                      reason: "tenant_audio_disabled"
                    }}

    assert %TenantSettings{
             allow_audio_calls: true,
             allow_public_channels: false,
             lock_version: 2
           } =
             Repo.get_by!(TenantSettings, tenant_id: tenant_id)
  end

  test "conversation archive rolls back when the Calls contribution fails" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{kind: "group", title: "Lifecycle rollback"},
               subject
             )

    tenant_id = account.tenant.id
    conversation_id = conversation.id

    replace_adapter(:conversation_call_lifecycle_adapter, FailingConversationAdapter)

    assert {:error, :forced_call_lifecycle_failure} =
             Conversations.archive(
               conversation.id,
               %{version: conversation.lock_version},
               subject
             )

    assert_receive {:conversation_call_lifecycle_contribution, true,
                    %CommsCore.Conversations.CallLifecycleCommand{
                      operation: :conversation_archived,
                      tenant_id: ^tenant_id,
                      conversation_id: ^conversation_id,
                      user_id: nil,
                      reason: "conversation_archived"
                    }}

    refute Repo.get!(Conversation, conversation.id).archived_at
  end

  test "conversation membership removal rolls back when the Calls contribution fails" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{kind: "group", title: "Lifecycle rollback", member_ids: [member.user.id]},
               subject
             )

    membership =
      Repo.get_by!(Membership,
        tenant_id: account.tenant.id,
        conversation_id: conversation.id,
        user_id: member.user.id
      )

    tenant_id = account.tenant.id
    conversation_id = conversation.id
    member_id = member.user.id

    replace_adapter(:conversation_call_lifecycle_adapter, FailingConversationAdapter)

    assert {:error, :forced_call_lifecycle_failure} =
             Conversations.remove_member(
               conversation.id,
               member.user.id,
               %{version: membership.lock_version},
               subject
             )

    assert_receive {:conversation_call_lifecycle_contribution, true,
                    %CommsCore.Conversations.CallLifecycleCommand{
                      operation: :membership_revoked,
                      tenant_id: ^tenant_id,
                      conversation_id: ^conversation_id,
                      user_id: ^member_id,
                      reason: "membership_removed"
                    }}

    refute Repo.get!(Membership, membership.id).left_at
  end

  defp replace_adapter(key, adapter) do
    previous = Application.fetch_env(:comms_core, key)
    Application.put_env(:comms_core, key, adapter)

    on_exit(fn ->
      case previous do
        {:ok, previous_adapter} -> Application.put_env(:comms_core, key, previous_adapter)
        :error -> Application.delete_env(:comms_core, key)
      end
    end)
  end
end
