defmodule CommsCore.Accounts.GovernanceErasureContributionsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, AudioCalls}

  alias CommsCore.Accounts.{
    Device,
    GovernanceErasureCommand,
    GovernanceErasureReceipt,
    Session,
    User
  }

  alias CommsCore.AudioCalls.{AudioCallParticipant, LifecycleCoordinator}
  alias CommsCore.Telephony.{Call, Number}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance
  @moduletag :call

  defmodule FailingCallLifecycleAdapter do
    @behaviour CommsCore.Accounts.CallLifecyclePort
    @impl true
    def revoke_identity_access(_command), do: {:error, :fixture_call_failure}
  end

  test "upfront identity drain revokes both call domains while final identity keys remain unchanged" do
    {account, participant_id} = admitted_participant()
    _remaining_owner = Fixtures.user_fixture(account, %{role: :owner})
    phone_call = connected_phone_call(account)
    command = command(account)

    assert {:ok, %GovernanceErasureReceipt{} = receipt} =
             Repo.transaction(fn ->
               assert {:ok, receipt} = Accounts.drain_user_for_governance(command)
               assert receipt.revoked_session_ids == [account.session.id]
               assert Repo.get!(User, account.user.id).email == account.user.email

               assert Repo.get!(User, account.user.id).external_subject ==
                        account.user.external_subject

               assert_revoked_and_queued(participant_id, "governance_user_erasure")
               assert_phone_ended_and_queued(phone_call.id)

               assert {:ok, %GovernanceErasureReceipt{user_id: user_id, revoked_session_ids: []}} =
                        Accounts.finalize_user_for_governance_erasure(command)

               assert user_id == account.user.id
               receipt
             end)

    assert receipt.user_id == account.user.id
    assert Repo.get!(User, account.user.id).status == :deleted
    assert Repo.get!(Session, account.session.id).revoked_at == command.timestamp
    assert Repo.get!(Device, account.device.id).revoked_at == command.timestamp
  end

  test "caller rollback restores identity, both call domains and their durable cleanup jobs" do
    {account, participant_id} = admitted_participant()
    _remaining_owner = Fixtures.user_fixture(account, %{role: :owner})
    phone_call = connected_phone_call(account)
    command = command(account)

    assert {:error, :fixture_governance_failure} =
             Repo.transaction(fn ->
               assert {:ok, _} = Accounts.drain_user_for_governance(command)
               assert {:ok, _} = Accounts.finalize_user_for_governance_erasure(command)
               Repo.rollback(:fixture_governance_failure)
             end)

    assert Repo.get!(User, account.user.id).email == account.user.email
    assert Repo.get!(User, account.user.id).status == :active
    refute Repo.get!(Session, account.session.id).revoked_at
    refute Repo.get!(Device, account.device.id).revoked_at
    assert Repo.get!(AudioCallParticipant, participant_id).status == :admitted
    assert Repo.get!(Call, phone_call.id).status == :answered

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 (job.worker == "CommsWorkers.TelephonyCleanupWorker" and
                    fragment("?->>'call_id'", job.args) == ^phone_call.id) or
                   (job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
                      fragment("?->>'participant_id'", job.args) == ^participant_id)
             )
           )
  end

  test "finalization refuses a target that has not been drained" do
    account = Fixtures.account_fixture()
    _remaining_owner = Fixtures.user_fixture(account, %{role: :owner})

    assert {:ok, {:error, :user_erasure_not_drained}} =
             Repo.transaction(fn ->
               Accounts.finalize_user_for_governance_erasure(command(account))
             end)

    assert Repo.get!(User, account.user.id).email == account.user.email
    refute Repo.get!(Session, account.session.id).revoked_at
    refute Repo.get!(Device, account.device.id).revoked_at
  end

  test "a failed configured call contribution rolls back the preceding identity drain" do
    account = Fixtures.account_fixture()
    _remaining_owner = Fixtures.user_fixture(account, %{role: :owner})
    previous = Application.fetch_env!(:comms_core, :identity_call_lifecycle_adapter)
    assert previous == LifecycleCoordinator

    Application.put_env(
      :comms_core,
      :identity_call_lifecycle_adapter,
      FailingCallLifecycleAdapter
    )

    on_exit(fn ->
      Application.put_env(:comms_core, :identity_call_lifecycle_adapter, previous)
    end)

    assert {:error, :user_erasure_failed} =
             Repo.transaction(fn ->
               case Accounts.drain_user_for_governance(command(account)) do
                 {:error, reason} -> Repo.rollback(reason)
                 {:ok, _} -> flunk("failed call contribution must refuse governed drain")
               end
             end)

    assert Repo.get!(User, account.user.id).status == :active
    refute Repo.get!(Session, account.session.id).revoked_at
    refute Repo.get!(Device, account.device.id).revoked_at
  end

  defp command(account),
    do: %GovernanceErasureCommand{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      pending_deletion_user_ids: [],
      timestamp: DateTime.utc_now()
    }

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
