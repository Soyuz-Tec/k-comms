defmodule CommsCore.Governance.UcMediaErasureTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{AudioCalls, Conversations, Governance, RuntimePorts, Telephony}
  alias CommsCore.Accounts.User
  alias CommsCore.AudioCalls.Artifacts.{Artifact, Segment}
  alias CommsCore.AudioCalls.{ArtifactProviderEvent, ArtifactProviderReceipt}
  alias CommsCore.AudioCalls.{ArtifactTranscript, ArtifactTranscriptSegment}
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Telephony.{Call, Mailboxes, Voicemail, VoicemailRead}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  defmodule CaptureProvider do
    def configured?, do: true
    def start(request), do: receipt(request, :recording)

    def stop(request) do
      send(self(), {:capture_stop_requested, request.artifact_id})
      receipt(request, :processing)
    end

    def reconcile(request), do: receipt(request, :recording)

    def verify_callback(body, "synthetic-verified-callback") do
      payload = Jason.decode!(body)

      {:ok,
       %ArtifactProviderEvent{
         event_id: payload["event_id"],
         event_type: "egress_ended",
         provider_job_id: payload["provider_job_id"],
         provider_room: payload["provider_room"],
         object_key: payload["object_key"],
         state: :available,
         byte_size: 4
       }}
    end

    def verify_callback(_, _), do: {:error, :invalid_provider_webhook}

    defp receipt(request, status) do
      {:ok,
       %ArtifactProviderReceipt{
         provider_job_id: request.provider_job_id || "EG_" <> request.artifact_id,
         provider_room: request.provider_room,
         object_key: request.object_key,
         state: status
       }}
    end
  end

  defmodule CaptureStorage do
    def verify(object) do
      {:ok,
       %{
         object
         | object_version_id: "captured-version",
           object_etag: "captured-etag",
           checksum_sha256: String.duplicate("a", 64),
           verified_checksum_sha256: String.duplicate("a", 64)
       }}
    end

    def download(object) do
      send(self(), {:capture_download, object.object_key})

      {:ok,
       %{
         url: "https://storage.example.test/captured?versionId=" <> object.object_version_id,
         approved_origin: "https://storage.example.test",
         expires_in: 60
       }}
    end

    def delete(object) do
      if Process.get(:capture_delete_unavailable) do
        {:error, :artifact_object_deletion_not_verified}
      else
        send(self(), {:capture_versions_purged, object.object_key})
        :ok
      end
    end
  end

  defmodule Transcription do
    def configured?, do: true

    def transcribe(_) do
      {:ok,
       %ArtifactTranscript{
         language: "en",
         segments: [
           %ArtifactTranscriptSegment{
             sequence: 0,
             start_ms: 0,
             end_ms: 1_000,
             text: "Restricted decision retained by the historical release"
           }
         ]
       }}
    end
  end

  defmodule PhoneControls do
    @behaviour CommsCore.Telephony.ProviderControlPort.Contract
    def capabilities(), do: %{voicemail: %{supported: true}}
    def authorize_destination(_), do: :ok
    def verify_event(_, _), do: {:error, :invalid_provider_webhook}
    def cleanup_call(_), do: {:error, :telephony_provider_unavailable}
    def bound_call_status(_), do: {:error, :telephony_provider_unavailable}
    def execute_control(_), do: {:error, :telephony_control_unsupported}
  end

  defmodule VoicemailProvider do
    @behaviour CommsCore.Telephony.VoicemailProviderPort.Contract
    def ready?, do: true

    def fetch(request) do
      {:ok,
       %{
         body: "bounded-synthetic-recording",
         content_type: "audio/wav",
         duration_seconds: 2,
         recording_name: request.recording_name
       }}
    end

    def delete(request) do
      if Process.get(:voicemail_provider_not_terminal) do
        {:error, :voicemail_source_deletion_pending}
      else
        send(self(), {:voicemail_source_purged, request.recording_name})
        :ok
      end
    end
  end

  defmodule VoicemailStorage do
    @behaviour CommsCore.Telephony.VoicemailStoragePort.Contract
    def ready?, do: true

    def ingest(object, _) do
      {:ok,
       %{
         object
         | object_version_id: "voicemail-version",
           object_etag: "voicemail-etag",
           verified_checksum_sha256: object.checksum_sha256
       }}
    end

    def download(object) do
      send(self(), {:voicemail_download, object.object_key})

      {:ok,
       %{
         url: "https://storage.example.test/voice?versionId=" <> object.object_version_id,
         approved_origin: "https://storage.example.test",
         development_http: false,
         expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         expires_in: 60,
         content_type: "audio/wav"
       }}
    end

    def delete(object) do
      if Process.get(:voicemail_delete_unavailable) do
        {:error, :storage_unavailable}
      else
        send(self(), {:voicemail_versions_purged, object.object_key})
        :ok
      end
    end
  end

  setup do
    settings = %{
      artifact_provider_adapter: CaptureProvider,
      artifact_storage_adapter: CaptureStorage,
      artifact_transcription_adapter: Transcription,
      artifact_protection_adapter: CommsCore.Governance.ArtifactProtection,
      telephony_control_adapter: PhoneControls,
      voicemail_provider_adapter: VoicemailProvider,
      voicemail_storage_adapter: VoicemailStorage,
      voicemail_protection_adapter: CommsCore.Governance.VoicemailProtection,
      direct_audio_p2p_enabled: false,
      meeting_artifact_policy: []
    }

    previous =
      Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    account = Fixtures.account_fixture()
    administrator = Fixtures.step_up(account)
    %{user: member} = Fixtures.user_fixture(account)

    {:ok, conversation} =
      Conversations.create(
        %{title: "Media erasure scope", kind: "group", member_ids: [member.id]},
        administrator
      )

    subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(account, member, "Media browser")

    Application.put_env(:comms_core, :meeting_artifact_policy,
      privacy_approved: true,
      provider_qualified: true,
      enabled_tenant_ids: [account.tenant.id]
    )

    {:ok, call, :created} = AudioCalls.start(conversation.id, subject)

    {:ok, _, _} =
      AudioCalls.with_join_authorized(conversation.id, call.id, subject, fn request ->
        {:ok, request.provider_identity}
      end)

    %{
      account: account,
      administrator: administrator,
      member: member,
      subject: subject,
      conversation: conversation,
      call: call
    }
  end

  test "approved user erasure waits for both media owners and removes saved text and read state",
       c do
    recording = available_recording!(c)
    transcript = transcript!(c, recording)
    voicemail = available_voicemail!(c)
    assert {:ok, _} = recording_playback(c, recording)
    assert_received {:capture_download, _}
    assert {:ok, _} = Telephony.voicemail_playback(voicemail.id, c.administrator)
    assert_received {:voicemail_download, _}
    assert {:ok, _} = Telephony.mark_voicemail_read(voicemail.id, c.administrator)
    assert Repo.exists?(from(r in VoicemailRead, where: r.voicemail_id == ^voicemail.id))

    request = approved_user_request!(c)
    claim = claim!(request)
    assert Repo.get!(DeletionRequest, request.id).status == :in_progress
    assert Repo.get!(Artifact, recording.id).erasure_requested_at
    assert Repo.get!(Artifact, transcript.id).erasure_requested_at
    assert Repo.get!(Voicemail, voicemail.id).erasure_requested_at

    assert {:ok, %{artifacts: []}} =
             AudioCalls.list_artifacts(c.conversation.id, c.call.id, c.subject)

    assert {:error, :artifact_not_available} = recording_playback(c, recording)

    assert {:error, :artifact_not_available} =
             AudioCalls.artifact_transcript(
               c.conversation.id,
               c.call.id,
               transcript.id,
               c.subject
             )

    assert {:ok, []} = AudioCalls.search_artifacts(c.subject, %{q: "Restricted decision"})
    assert {:ok, %{messages: []}} = Telephony.list_voicemails(c.administrator, %{})
    assert {:error, :not_found} = Telephony.voicemail_playback(voicemail.id, c.administrator)
    assert {:error, :not_found} = Telephony.mark_voicemail_read(voicemail.id, c.administrator)
    refute_received {:capture_download, _}
    refute_received {:voicemail_download, _}
    assert_pending!(claim)
    assert Repo.get!(User, c.member.id).status == :active

    Process.put(:capture_delete_unavailable, true)
    assert {:error, :artifact_object_deletion_not_verified} = process_artifact(recording.id)
    assert_pending!(claim)
    Process.delete(:capture_delete_unavailable)
    assert {:ok, :deleted} = process_artifact(recording.id)
    assert_received {:capture_versions_purged, _}
    assert_pending!(claim)
    assert {:ok, :deleted} = process_artifact(transcript.id)
    refute Repo.exists?(from(s in Segment, where: s.artifact_id == ^transcript.id))
    assert_pending!(claim)

    Process.put(:voicemail_provider_not_terminal, true)
    assert {:error, :voicemail_source_deletion_pending} = purge_voicemail(voicemail.id)
    refute_received {:voicemail_versions_purged, _}
    assert_pending!(claim)
    Process.delete(:voicemail_provider_not_terminal)
    Process.put(:voicemail_delete_unavailable, true)
    assert {:error, :storage_unavailable} = purge_voicemail(voicemail.id)
    assert Repo.get!(Voicemail, voicemail.id).status == :deleting
    assert is_nil(Repo.get!(Voicemail, voicemail.id).erasure_verified_at)
    assert_pending!(claim)
    Process.delete(:voicemail_delete_unavailable)
    assert {:ok, :deleted} = purge_voicemail(voicemail.id)
    assert_received {:voicemail_source_purged, _}
    assert_received {:voicemail_versions_purged, _}
    refute Repo.exists?(from(r in VoicemailRead, where: r.voicemail_id == ^voicemail.id))

    assert {:ok, %{request: completed}} = complete(claim)
    assert completed.status == :completed
    assert evidence(completed, :media_erasure_version) == 1
    assert evidence(completed, :derived_erasure_version) == 1
    assert evidence(completed, :meeting_erasure_version) == 1
    assert Repo.get!(User, c.member.id).status == :deleted
    assert Repo.get!(User, c.account.user.id).status == :active
    assert {:error, :already_delivered} = complete(claim)
  end

  test "conversation erasure cannot certify completion while capture can still write its object",
       c do
    recording = start_recording!(c)

    {:ok, %{request: request}} =
      Governance.create_deletion_request(
        %{
          target_type: :conversation,
          conversation_id: c.conversation.id,
          reason: "Verified erase"
        },
        c.administrator
      )

    request = approve!(request, c.administrator)
    claim = claim!(request)
    assert Repo.get!(Artifact, recording.id).status == :stopping
    assert_pending!(claim)
    assert {:ok, :provider_updated} = process_artifact(recording.id)
    assert_received {:capture_stop_requested, recording_id}
    assert recording_id == recording.id
    refute_received {:capture_versions_purged, _}
    assert_pending!(claim)

    finish_capture!(recording.id)
    assert {:ok, :deleted} = process_artifact(recording.id)
    assert_received {:capture_versions_purged, _}
    assert {:ok, %{request: completed}} = complete(claim)
    assert evidence(completed, :media_erasure_version) == 1
  end

  test "a held voicemail participant rolls back the earlier recording plan and the entire claim",
       c do
    recording = available_recording!(c)
    voicemail = available_voicemail!(c)
    request = approved_user_request!(c)
    jobs_before = Repo.aggregate(Oban.Job, :count)

    # This owner is not the deletion target or an admitted recording participant.
    # Its hold is discovered by the voicemail owner after recording preparation.
    assert {:ok, %{hold: hold}} =
             Governance.create_legal_hold(
               %{
                 scope_type: :user,
                 subject_user_id: c.account.user.id,
                 name: "Preserve mailbox owner",
                 reason: "Synthetic mailbox preservation"
               },
               c.administrator
             )

    assert {:error, :legal_hold_active} =
             Governance.claim_deletion_request(request.id, RuntimePorts.job_worker!(:deletion))

    unchanged = Repo.get!(DeletionRequest, request.id)
    assert unchanged.status == :approved
    assert unchanged.lock_version == request.lock_version
    assert unchanged.execution_attempts == 0
    assert is_nil(Repo.get!(Artifact, recording.id).erasure_requested_at)
    assert Repo.get!(Artifact, recording.id).status == :available
    assert is_nil(Repo.get!(Voicemail, voicemail.id).erasure_requested_at)
    assert Repo.get!(Voicemail, voicemail.id).status == :available
    assert Repo.aggregate(Oban.Job, :count) == jobs_before
    refute_received {:capture_versions_purged, _}
    refute_received {:voicemail_source_purged, _}
    refute_received {:voicemail_versions_purged, _}

    assert {:ok, _} =
             Governance.release_legal_hold(
               hold.id,
               %{version: hold.lock_version, release_reason: "Synthetic investigation closed"},
               c.administrator
             )

    assert %{request_id: id} = claim!(request)
    assert id == request.id
    assert Repo.get!(Artifact, recording.id).erasure_requested_at
    assert Repo.get!(Voicemail, voicemail.id).erasure_requested_at
  end

  test "historical completion receives media proof only after retained provider sources are purged",
       c do
    recording = available_recording!(c)
    transcript = transcript!(c, recording)
    voicemail = available_voicemail!(c)
    assert {:ok, _} = Telephony.mark_voicemail_read(voicemail.id, c.administrator)
    request = approved_user_request!(c)

    # Seed the historical receipt shape: earlier releases marked the target
    # complete without certifying removal of separately owned media sources.
    request
    |> DeletionRequest.changeset(%{
      status: :completed,
      completed_at: DateTime.utc_now(),
      evidence: %{derived_erasure_version: 1, deleted_object_count: 0}
    })
    |> Repo.update!()

    assert {:error, :forbidden} = Governance.reconcile_completed_erasure(__MODULE__, 1)
    worker = RuntimePorts.job_worker!(:erasure_reconciler)

    assert {:ok, %{repaired: 0, has_more: true}} =
             Governance.reconcile_completed_erasure(worker, 1)

    pending = Repo.get!(DeletionRequest, request.id)
    assert pending.status == :completed
    assert is_nil(evidence(pending, :media_erasure_version))
    assert is_nil(evidence(pending, :derived_erasure_repaired_at))
    assert {:ok, _, 0} = DateTime.from_iso8601(evidence(pending, :media_erasure_checked_at))
    assert Repo.get!(Artifact, recording.id).erasure_requested_at
    assert Repo.get!(Voicemail, voicemail.id).erasure_requested_at
    assert {:error, :artifact_not_available} = recording_playback(c, recording)
    assert {:error, :not_found} = Telephony.voicemail_playback(voicemail.id, c.administrator)

    assert {:ok, :deleted} = process_artifact(recording.id)
    assert {:ok, :deleted} = process_artifact(transcript.id)
    Process.put(:voicemail_delete_unavailable, true)
    assert {:error, :storage_unavailable} = purge_voicemail(voicemail.id)

    assert {:ok, %{repaired: 0, has_more: true}} =
             Governance.reconcile_completed_erasure(worker, 1)

    assert is_nil(evidence(Repo.get!(DeletionRequest, request.id), :media_erasure_version))
    Process.delete(:voicemail_delete_unavailable)
    assert {:ok, :deleted} = purge_voicemail(voicemail.id)

    assert {:ok, %{repaired: 1, has_more: true}} =
             Governance.reconcile_completed_erasure(worker, 1)

    repaired = Repo.get!(DeletionRequest, request.id)
    assert evidence(repaired, :media_erasure_version) == 1
    assert evidence(repaired, :meeting_erasure_version) == 1
    assert {:ok, _, 0} = DateTime.from_iso8601(evidence(repaired, :derived_erasure_repaired_at))
    refute Repo.exists?(from(s in Segment, where: s.artifact_id == ^transcript.id))
    refute Repo.exists?(from(r in VoicemailRead, where: r.voicemail_id == ^voicemail.id))

    assert {:ok, %{repaired: 0, has_more: false}} =
             Governance.reconcile_completed_erasure(worker, 1)
  end

  defp approved_user_request!(c) do
    {:ok, %{request: request}} =
      Governance.create_deletion_request(
        %{
          target_type: :user,
          subject_user_id: c.member.id,
          reason: "Verified media account erase"
        },
        c.administrator
      )

    approve!(request, c.administrator)
  end

  defp approve!(request, subject) do
    {:ok, approved} =
      Governance.transition_deletion_request(
        request.id,
        %{
          version: request.lock_version,
          status: :approved,
          transition_reason: "Synthetic request independently verified"
        },
        subject
      )

    approved
  end

  defp claim!(request) do
    {:ok, claim} =
      Governance.claim_deletion_request(request.id, RuntimePorts.job_worker!(:deletion))

    claim
  end

  defp complete(claim) do
    Governance.complete_deletion_request(
      claim.request_id,
      claim.expected_version,
      %{deleted_object_count: 0},
      RuntimePorts.job_worker!(:deletion)
    )
  end

  defp assert_pending!(claim) do
    assert {:error, :media_erasure_pending} = complete(claim)
    request = Repo.get!(DeletionRequest, claim.request_id)
    assert request.status == :in_progress
    assert request.lock_version == claim.expected_version
    assert is_nil(evidence(request, :media_erasure_version))
  end

  defp evidence(request, key), do: request.evidence[key] || request.evidence[Atom.to_string(key)]

  defp recording_playback(c, recording),
    do: AudioCalls.artifact_playback(c.conversation.id, c.call.id, recording.id, c.subject)

  defp process_artifact(id),
    do: AudioCalls.process_artifact(id, RuntimePorts.job_worker!(:call_artifact))

  defp purge_voicemail(id),
    do: Telephony.purge_voicemail(id, RuntimePorts.job_worker!(:telephony_voicemail))

  defp start_recording!(c) do
    {:ok, recording} =
      AudioCalls.request_artifact(
        c.conversation.id,
        c.call.id,
        %{idempotency_key: "governance-recording"},
        c.subject
      )

    {:ok, _} =
      AudioCalls.consent_artifact(c.conversation.id, c.call.id, recording.id, true, c.subject)

    {:ok, _} = AudioCalls.start_artifact(c.conversation.id, c.call.id, recording.id, c.subject)
    {:ok, :provider_updated} = process_artifact(recording.id)
    recording
  end

  defp available_recording!(c) do
    recording = start_recording!(c)
    finish_capture!(recording.id)
    {:ok, _} = process_artifact(recording.id)
    recording
  end

  defp finish_capture!(id) do
    recording = Repo.get!(Artifact, id)

    body =
      Jason.encode!(%{
        event_id: "capture-finished-" <> id,
        provider_job_id: recording.provider_job_id,
        provider_room: recording.provider_room,
        object_key: recording.object_key
      })

    {:ok, _} = AudioCalls.handle_artifact_callback(body, "synthetic-verified-callback")
  end

  defp transcript!(c, recording) do
    {:ok, transcript} =
      AudioCalls.request_artifact(
        c.conversation.id,
        c.call.id,
        %{
          kind: :transcript,
          source_artifact_id: recording.id,
          idempotency_key: "governance-transcript"
        },
        c.subject
      )

    {:ok, :transcribed} = process_artifact(transcript.id)
    transcript
  end

  defp available_voicemail!(c) do
    {:ok, _} =
      Telephony.provision(
        %{
          phone_number: "+14155550100",
          extension: "101",
          user_id: c.member.id,
          inbound_trunk_id: "ST_inbound",
          outbound_trunk_id: "ST_outbound",
          reason: "Synthetic erasure line"
        },
        c.administrator
      )

    {:ok, _} =
      Telephony.save_mailbox(
        %{
          user_id: c.account.user.id,
          enabled: true,
          retention_days: 30,
          notice_media: "sound:custom/recording-notice",
          reason: "Synthetic surviving mailbox owner"
        },
        c.administrator
      )

    {:ok, call, :created} =
      Telephony.start_outbound(
        %{destination: "+14155550200", idempotency_key: "governance-voicemail"},
        c.subject
      )

    {:ok, _} = Repo.transaction(fn -> Mailboxes.reserve!(Repo.get!(Call, call.id)) end)
    voicemail = Repo.get_by!(Voicemail, call_id: call.id)
    caller = RuntimePorts.job_worker!(:telephony_voicemail)
    {:ok, request} = Telephony.claim_voicemail(voicemail.id, caller)
    {:ok, media} = CommsCore.Telephony.VoicemailProviderPort.fetch(request)
    {:ok, :available} = Telephony.store_voicemail(voicemail.id, media, caller)
    voicemail
  end
end
