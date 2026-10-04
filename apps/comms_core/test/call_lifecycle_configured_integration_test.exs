defmodule CommsCore.CallLifecycleConfiguredIntegrationTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :call

  alias CommsCore.Accounts.CallLifecycleCommand, as: IdentityCommand
  alias CommsCore.Accounts.CallLifecyclePort, as: IdentityPort
  alias CommsCore.Accounts.CallLifecycleReceipt, as: IdentityReceipt

  alias CommsCore.Administration.CallLifecycleCommand, as: TenantCommand
  alias CommsCore.Administration.CallLifecyclePort, as: TenantPort
  alias CommsCore.Administration.CallLifecycleReceipt, as: TenantReceipt

  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.AudioCallParticipant
  alias CommsCore.AudioCalls.LifecycleCoordinator
  alias CommsCore.Telephony.{Call, Number}

  alias CommsCore.Conversations.CallLifecycleCommand, as: ConversationCommand
  alias CommsCore.Conversations.CallLifecyclePort, as: ConversationPort
  alias CommsCore.Conversations.CallLifecycleReceipt, as: ConversationReceipt

  alias CommsTestSupport.Fixtures

  setup do
    assert Application.fetch_env!(:comms_core, :identity_call_lifecycle_adapter) ==
             LifecycleCoordinator

    assert Application.fetch_env!(:comms_core, :tenant_call_lifecycle_adapter) ==
             LifecycleCoordinator

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
      phone_call = connected_phone_call(account)

      assert {:ok, {:ok, %IdentityReceipt{revoked_participant_count: 2}}} =
               Repo.transaction(fn ->
                 account
                 |> command_builder.()
                 |> IdentityPort.revoke_identity_access()
               end)

      assert_revoked_and_queued(participant_id, reason)
      assert_phone_ended_and_queued(phone_call.id)
    end)
  end

  test "the configured TenantAdministration port maps media disablement to Calls revocation" do
    {account, participant_id} = admitted_participant()
    phone_call = connected_phone_call(account)

    command =
      TenantCommand.tenant_media_disabled(
        account.tenant.id,
        :audio,
        "tenant_audio_disabled"
      )

    assert {:ok, {:ok, %TenantReceipt{revoked_participant_count: 2}}} =
             Repo.transaction(fn -> TenantPort.revoke_tenant_media(command) end)

    assert_revoked_and_queued(participant_id, "tenant_audio_disabled")
    assert_phone_ended_and_queued(phone_call.id)
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

  test "a surrounding transaction rolls back both domains and their durable jobs" do
    {account, participant_id} = admitted_participant()
    phone_call = connected_phone_call(account)

    command =
      IdentityCommand.sessions_revoked(account.tenant.id, [account.session.id], "session_logout")

    assert {:error, :forced_identity_failure} =
             Repo.transaction(fn ->
               assert {:ok, %IdentityReceipt{revoked_participant_count: 2}} =
                        IdentityPort.revoke_identity_access(command)

               Repo.rollback(:forced_identity_failure)
             end)

    assert Repo.get!(AudioCallParticipant, participant_id).status == :admitted
    assert Repo.get!(Call, phone_call.id).status == :answered

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.TelephonyCleanupWorker" and
                   fragment("?->>'call_id'", job.args) == ^phone_call.id
             )
           )
  end

  test "the coordinator refuses revocation outside the owning transaction" do
    account = Fixtures.account_fixture()

    assert {:error, :transaction_required} =
             LifecycleCoordinator.revoke_identity_access(
               IdentityCommand.sessions_revoked(
                 account.tenant.id,
                 [account.session.id],
                 "session_logout"
               )
             )

    assert {:error, :transaction_required} =
             LifecycleCoordinator.revoke_tenant_media(
               TenantCommand.tenant_media_disabled(
                 account.tenant.id,
                 :audio,
                 "tenant_audio_disabled"
               )
             )
  end

  defp connected_phone_call(account) do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
    phone_number = "+1555" <> String.pad_leading(suffix, 7, "0")

    number =
      %Number{}
      |> Number.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        phone_number: phone_number,
        extension: "101",
        inbound_trunk_id: "ST_inbound",
        outbound_trunk_id: "ST_outbound"
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Call{}
    |> Call.changeset(%{
      tenant_id: account.tenant.id,
      number_id: number.id,
      user_id: account.user.id,
      direction: :outbound,
      status: :answered,
      from_number: phone_number,
      to_number: "+15555550199",
      extension: "101",
      inbound_trunk_id: number.inbound_trunk_id,
      outbound_trunk_id: number.outbound_trunk_id,
      provider_room: "telephony-" <> Ecto.UUID.generate(),
      provider_identity: "sip-" <> Ecto.UUID.generate(),
      answer_session_id: account.session.id,
      answer_device_id: account.device.id,
      app_identity: "app-" <> Ecto.UUID.generate(),
      app_connected_at: now,
      app_provider_sid: "PA_" <> Ecto.UUID.generate(),
      app_event_at: now,
      dispatch_status: :started,
      started_at: DateTime.add(now, -20, :second),
      answered_at: DateTime.add(now, -10, :second),
      expires_at: DateTime.add(now, 600, :second)
    })
    |> Repo.insert!()
  end

  defp assert_phone_ended_and_queued(call_id) do
    assert %Call{status: status, ended_at: %DateTime{}} = Repo.get!(Call, call_id)
    assert status in [:ended, :cancelled]

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.TelephonyCleanupWorker" and
                   fragment("?->>'call_id'", job.args) == ^call_id
             )
           )
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
