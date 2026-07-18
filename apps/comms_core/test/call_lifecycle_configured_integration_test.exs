defmodule CommsCore.CallLifecycleConfiguredIntegrationTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.CallLifecycleCommand, as: IdentityCommand
  alias CommsCore.Accounts.CallLifecyclePort, as: IdentityPort
  alias CommsCore.Accounts.CallLifecycleReceipt, as: IdentityReceipt

  alias CommsCore.Administration.CallLifecycleCommand, as: TenantCommand
  alias CommsCore.Administration.CallLifecyclePort, as: TenantPort
  alias CommsCore.Administration.CallLifecycleReceipt, as: TenantReceipt

  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.AudioCallParticipant

  alias CommsCore.Conversations.CallLifecycleCommand, as: ConversationCommand
  alias CommsCore.Conversations.CallLifecyclePort, as: ConversationPort
  alias CommsCore.Conversations.CallLifecycleReceipt, as: ConversationReceipt

  alias CommsTestSupport.Fixtures

  setup do
    assert Application.fetch_env!(:comms_core, :identity_call_lifecycle_adapter) == AudioCalls
    assert Application.fetch_env!(:comms_core, :tenant_call_lifecycle_adapter) == AudioCalls
    assert Application.fetch_env!(:comms_core, :conversation_call_lifecycle_adapter) == AudioCalls

    :ok
  end

  test "the configured IdentityAccess port maps every command to Calls revocation" do
    cases = [
      {
        fn account ->
          IdentityCommand.sessions_revoked(
            account.tenant.id,
            [account.session.id],
            "session_logout"
          )
        end,
        "session_logout"
      },
      {
        fn account ->
          IdentityCommand.device_revoked(
            account.tenant.id,
            account.device.id,
            "device_revoked"
          )
        end,
        "device_revoked"
      },
      {
        fn account ->
          IdentityCommand.user_access_revoked(
            account.tenant.id,
            account.user.id,
            "user_lifecycle_revoked"
          )
        end,
        "user_lifecycle_revoked"
      }
    ]

    Enum.each(cases, fn {command_builder, reason} ->
      {account, participant_id} = admitted_participant()

      assert {:ok, {:ok, %IdentityReceipt{revoked_participant_count: 1}}} =
               Repo.transaction(fn ->
                 account
                 |> command_builder.()
                 |> IdentityPort.revoke_identity_access()
               end)

      assert_revoked_and_queued(participant_id, reason)
    end)
  end

  test "the configured TenantAdministration port maps media disablement to Calls revocation" do
    {account, participant_id} = admitted_participant()

    command =
      TenantCommand.tenant_media_disabled(
        account.tenant.id,
        :audio,
        "tenant_audio_disabled"
      )

    assert {:ok, {:ok, %TenantReceipt{revoked_participant_count: 1}}} =
             Repo.transaction(fn -> TenantPort.revoke_tenant_media(command) end)

    assert_revoked_and_queued(participant_id, "tenant_audio_disabled")
  end

  test "the configured Conversations port maps membership and archive commands to Calls revocation" do
    cases = [
      {
        fn account ->
          ConversationCommand.membership_revoked(
            account.tenant.id,
            account.conversation.id,
            account.user.id,
            "membership_removed"
          )
        end,
        "membership_removed"
      },
      {
        fn account ->
          ConversationCommand.conversation_archived(
            account.tenant.id,
            account.conversation.id,
            "conversation_archived"
          )
        end,
        "conversation_archived"
      }
    ]

    Enum.each(cases, fn {command_builder, reason} ->
      {account, participant_id} = admitted_participant()

      assert {:ok, {:ok, %ConversationReceipt{revoked_participant_count: 1}}} =
               Repo.transaction(fn ->
                 account
                 |> command_builder.()
                 |> ConversationPort.revoke_conversation_access()
               end)

      assert_revoked_and_queued(participant_id, reason)
    end)
  end

  defp admitted_participant do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, call, :created} =
             AudioCalls.start(account.conversation.id, subject)

    assert {:ok, _call, participant_id} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn request -> {:ok, request.participant_id} end
             )

    assert %AudioCallParticipant{status: :admitted, eviction_status: :not_required} =
             Repo.get!(AudioCallParticipant, participant_id)

    {account, participant_id}
  end

  defp assert_revoked_and_queued(participant_id, reason) do
    assert %AudioCallParticipant{
             status: :revoked,
             eviction_status: :pending,
             revocation_reason: ^reason,
             revoked_at: %DateTime{},
             eviction_enforce_until: %DateTime{}
           } = Repo.get!(AudioCallParticipant, participant_id)

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
                   fragment("?->>'participant_id'", job.args) == ^participant_id
             )
           )
  end
end
