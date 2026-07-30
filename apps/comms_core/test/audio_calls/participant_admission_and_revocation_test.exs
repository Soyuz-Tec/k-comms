defmodule CommsCore.AudioCalls.ParticipantAdmissionAndRevocationTest do
  use CommsCore.DataCase, async: false

  @moduletag :call
  @moduletag :integration

  alias CommsCore.Accounts
  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCallParticipant, CallView, CredentialRequest}
  alias CommsTestSupport.Fixtures

  test "admission creation, reuse, and credential issuance are atomic without token persistence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    issuer = fn %CredentialRequest{} = request ->
      assert request.call_id == call.id
      assert request.participant_id
      assert request.provider_identity =~ "kc_"
      {:ok, %{participant_token: "must-never-be-persisted", server_url: "wss://audio.test"}}
    end

    assert {:ok, ^call, credential} =
             AudioCalls.with_join_authorized(account.conversation.id, call.id, subject, issuer)

    assert credential.participant_token == "must-never-be-persisted"
    participant = Repo.one!(AudioCallParticipant)
    assert participant.status == :admitted
    assert participant.credential_issue_count == 1
    assert participant.credential_issued_at
    refute inspect(participant) =~ "must-never-be-persisted"

    first_identity = participant.provider_identity

    assert {:ok, ^call, _credential} =
             AudioCalls.with_join_authorized(account.conversation.id, call.id, subject, issuer)

    reused = Repo.one!(AudioCallParticipant)
    assert reused.id == participant.id
    assert reused.provider_identity == first_identity
    assert reused.credential_issue_count == 2

    other = Fixtures.account_fixture()
    other_subject = Fixtures.subject(other)
    assert {:ok, other_call, :created} = AudioCalls.start(other.conversation.id, other_subject)

    assert {:error, :forced_issuer_failure} =
             AudioCalls.with_join_authorized(
               other.conversation.id,
               other_call.id,
               other_subject,
               fn _request -> {:error, :forced_issuer_failure} end
             )

    refute Repo.get_by(AudioCallParticipant, audio_call_id: other_call.id)
  end

  test "every revocation scope creates an immutable replacement admission and durable eviction job" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    scopes = [
      fn ->
        AudioCalls.revoke_for_sessions(account.tenant.id, [account.session.id], "session_revoked")
      end,
      fn ->
        AudioCalls.revoke_for_device(account.tenant.id, account.device.id, "device_revoked")
      end,
      fn -> AudioCalls.revoke_for_user(account.tenant.id, account.user.id, "user_revoked") end,
      fn ->
        AudioCalls.revoke_for_membership(
          account.tenant.id,
          account.conversation.id,
          account.user.id,
          "membership_removed"
        )
      end,
      fn ->
        AudioCalls.revoke_for_conversation(
          account.tenant.id,
          account.conversation.id,
          "conversation_archived"
        )
      end,
      fn -> AudioCalls.revoke_for_tenant(account.tenant.id, "tenant_audio_disabled") end,
      fn -> AudioCalls.revoke_for_call(account.tenant.id, call.id, "call_ended") end
    ]

    identities =
      Enum.map(scopes, fn revoke ->
        assert {:ok, ^call, identity} =
                 AudioCalls.with_join_authorized(
                   account.conversation.id,
                   call.id,
                   subject,
                   fn request -> {:ok, request.provider_identity} end
                 )

        assert {:ok, 1} = revoke.()
        identity
      end)

    assert length(Enum.uniq(identities)) == length(scopes)

    participants =
      AudioCallParticipant
      |> where([participant], participant.audio_call_id == ^call.id)
      |> order_by([participant], asc: participant.admitted_at)
      |> Repo.all()

    assert length(participants) == length(scopes)

    assert Enum.all?(participants, fn participant ->
             (participant.status == :revoked and participant.eviction_status == :pending and
                participant.revoked_at) && participant.eviction_enforce_until &&
               is_nil(participant.last_eviction_attempt_at)
           end)

    participant_ids = Enum.map(participants, & &1.id)

    jobs =
      Repo.all(
        from(job in Oban.Job,
          where:
            job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
              fragment("?->>'participant_id'", job.args) in ^participant_ids
        )
      )

    assert length(jobs) == length(scopes)
  end

  test "later identity revocation does not enqueue historical-call eviction work again" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:ok, ^call, :credential} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn _request -> {:ok, :credential} end
             )

    assert {:ok, %CallView{status: :ended}} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{reason: "owner_ended"},
               subject,
               fn _ending_call -> :ok end
             )

    participant = Repo.get_by!(AudioCallParticipant, audio_call_id: call.id)
    assert participant.status == :revoked
    assert participant.revocation_reason == "call_ended"
    jobs_before = eviction_job_count(participant.id)
    assert jobs_before == 1

    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)
    assert eviction_job_count(participant.id) == jobs_before
  end

  defp eviction_job_count(participant_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
            fragment("?->>'participant_id'", job.args) == ^participant_id
      ),
      :count
    )
  end
end
