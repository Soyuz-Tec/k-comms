defmodule CommsCore.AudioCalls.ArtifactsTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Accounts, AudioCalls, Conversations, Repo, RuntimePorts}

  alias CommsCore.AudioCalls.{
    ArtifactProviderReceipt,
    ArtifactProviderEvent,
    ArtifactStorageObject,
    ArtifactTranscript,
    ArtifactTranscriptSegment,
    Artifacts
  }

  alias CommsCore.AudioCalls.Artifacts.{Artifact, Segment}
  alias CommsTestSupport.Fixtures

  defmodule Provider do
    def configured?, do: true

    def start(request) do
      send(self(), {:provider_started, request})
      {:ok, receipt(request, :recording)}
    end

    def stop(request) do
      send(self(), {:provider_stopped, request})
      {:ok, receipt(request, :processing)}
    end

    def reconcile(request), do: {:ok, receipt(request, :recording)}

    def verify_callback(body, "verified") do
      event = Jason.decode!(body)

      {:ok,
       %ArtifactProviderEvent{
         event_id: event["event_id"],
         event_type: "egress_ended",
         provider_job_id: event["provider_job_id"],
         provider_room: event["provider_room"],
         object_key: event["object_key"],
         state: :available,
         byte_size: event["byte_size"]
       }}
    end

    def verify_callback(_, _), do: {:error, :invalid_provider_webhook}

    defp receipt(request, state),
      do: %ArtifactProviderReceipt{
        provider_job_id: request.provider_job_id || "EG_" <> request.artifact_id,
        provider_room: request.provider_room,
        object_key: request.object_key,
        state: state
      }
  end

  defmodule Storage do
    def verify(%ArtifactStorageObject{} = object),
      do:
        {:ok,
         %ArtifactStorageObject{
           object
           | object_version_id: "version-1",
             object_etag: "etag-1",
             checksum_sha256: String.duplicate("a", 64),
             verified_checksum_sha256: String.duplicate("a", 64)
         }}

    def download(object) do
      send(self(), {:object_downloaded, object.object_key})

      {:ok,
       %{
         url: "https://storage.example.test/approved",
         approved_origin: "https://storage.example.test",
         expires_in: 60
       }}
    end

    def delete(object) do
      send(self(), {:object_deleted, object.object_key})
      :ok
    end
  end

  defmodule Transcription do
    def configured?, do: true

    def transcribe(request) do
      send(
        self(),
        {:transcription_source, request.object.object_version_id, request.object.checksum_sha256}
      )

      {:ok,
       %ArtifactTranscript{
         language: "en",
         segments: [
           %ArtifactTranscriptSegment{
             sequence: 0,
             start_ms: 0,
             end_ms: 1_000,
             text: "Meeting decision <script>"
           }
         ]
       }}
    end
  end

  defmodule UnverifiedStorage do
    def verify(_), do: {:error, :artifact_object_verification_failed}
    defdelegate download(object), to: Storage
    defdelegate delete(object), to: Storage
  end

  defmodule UnavailableDeletionStorage do
    defdelegate verify(object), to: Storage
    defdelegate download(object), to: Storage
    def delete(_), do: {:error, :artifact_object_deletion_not_verified}
  end

  defmodule RejectedTranscription do
    def configured?(), do: true
    def transcribe(_), do: {:error, :invalid_artifact_transcription_request}
  end

  setup do
    keys = [
      :artifact_provider_adapter,
      :artifact_storage_adapter,
      :artifact_transcription_adapter,
      :artifact_protection_adapter,
      :direct_audio_p2p_enabled,
      :meeting_artifact_policy
    ]

    old = Enum.map(keys, &{&1, Application.fetch_env(:comms_core, &1)})

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    Application.put_env(:comms_core, :artifact_provider_adapter, Provider)
    Application.put_env(:comms_core, :artifact_storage_adapter, Storage)
    Application.put_env(:comms_core, :artifact_transcription_adapter, Transcription)

    Application.put_env(
      :comms_core,
      :artifact_protection_adapter,
      CommsCore.Governance.ArtifactProtection
    )

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    admit!(account.conversation.id, call.id, subject)
    %{account: account, subject: subject, call: call}
  end

  test "rollback refuses proof when owned transcript inventory is absent" do
    # DataCase rolls back this DDL with the isolated synthetic test transaction.
    Repo.query!("DROP TABLE public.call_artifact_segments")

    assert_raise RuntimeError, "Calls artifact rollback inventory unavailable", fn ->
      AudioCalls.rollback_artifact_hazard_count()
    end
  end

  test "rollback hazards retain consent, verified media and transcript dependencies until physical erasure",
       context do
    enable!(context)
    assert Artifacts.rollback_hazard_count() == 0
    recording = available_recording!(context)
    assert Artifacts.rollback_hazard_count() == 1
    {:ok, transcript} = request_transcript!(context, recording)
    assert Artifacts.rollback_hazard_count() == 2
    assert {:ok, :transcribed} = process(transcript.id)
    assert Artifacts.rollback_hazard_count() == 3

    {:ok, _} =
      Artifacts.delete(
        context.account.conversation.id,
        context.call.id,
        recording.id,
        context.subject
      )

    assert Artifacts.rollback_hazard_count() == 3
    assert {:ok, :deleted} = process(recording.id)
    assert Artifacts.rollback_hazard_count() == 2
    assert {:ok, :deleted} = process(transcript.id)
    assert Artifacts.rollback_hazard_count() == 0

    # Merely relabeling metadata as deleted cannot attest cleanup.
    Repo.get!(Artifact, recording.id)
    |> Ecto.Changeset.change(deleted_at: nil)
    |> Repo.update!()

    assert Artifacts.rollback_hazard_count() == 1
  end

  test "capture defaults off and never starts before every admitted session consents", context do
    Application.put_env(:comms_core, :meeting_artifact_policy, [])
    refute Artifacts.capabilities(context.subject).recording
    assert {:error, :recording_disabled} = request(context)
    enable!(context)
    assert {:ok, artifact} = request(context)
    assert artifact.status == :pending_consent
    assert artifact.my_consent == false

    assert {:error, :recording_consent_required} =
             Artifacts.start(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               context.subject
             )

    refute_received {:provider_started, _}

    assert {:ok, _} =
             Artifacts.consent(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               true,
               context.subject
             )

    assert {:ok, started} =
             Artifacts.start(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               context.subject
             )

    assert started.status == :starting
    assert {:ok, :provider_updated} = process(artifact.id)
    assert_received {:provider_started, request}

    assert request.object_key ==
             "#{context.account.tenant.id}/meeting-artifacts/#{context.call.id}/#{artifact.id}.mp4"
  end

  test "an expired admitted session cancels queued capture before the provider effect", context do
    enable!(context)
    artifact = queued_recording!(context)

    Repo.get!(Accounts.Session, context.subject.session_id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :artifact_start_authorization_changed} = process(artifact.id)
    refute_received {:provider_started, _}
    row = Repo.get!(Artifact, artifact.id)
    assert row.status == :failed
    assert row.failure_code == "capture_authorization_changed"
    assert is_nil(row.provider_job_id)
  end

  test "withdrawal before a worker claims capture never starts or stops an imaginary provider job",
       context do
    enable!(context)
    artifact = queued_recording!(context)

    assert {:ok, _} =
             Artifacts.consent(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               false,
               context.subject
             )

    assert {:ok, :idle} = process(artifact.id)
    refute_received {:provider_started, _}
    refute_received {:provider_stopped, _}
    row = Repo.get!(Artifact, artifact.id)
    assert row.status == :failed
    assert is_nil(row.provider_start_claimed_at)
  end

  test "direct audio configuration cannot silently omit media from a recording", context do
    enable!(context)
    {:ok, artifact} = request(context)

    {:ok, _} =
      Artifacts.consent(
        context.account.conversation.id,
        context.call.id,
        artifact.id,
        true,
        context.subject
      )

    Application.put_env(:comms_core, :direct_audio_p2p_enabled, true)
    refute Artifacts.capabilities(context.subject).recording

    assert {:error, :recording_requires_livekit} =
             Artifacts.start(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               context.subject
             )

    refute_received {:provider_started, _}
  end

  test "new sessions wait during capture and withdrawing consent durably requests stop",
       context do
    enable!(context)
    artifact = start_recording!(context)

    assert :ok =
             Artifacts.authorize_admission(
               context.account.tenant.id,
               context.call.id,
               context.subject.session_id
             )

    assert {:error, :recording_consent_admission_blocked} =
             Artifacts.authorize_admission(
               context.account.tenant.id,
               context.call.id,
               Ecto.UUID.generate()
             )

    assert {:ok, stopped} =
             Artifacts.consent(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               false,
               context.subject
             )

    assert stopped.status == :stopping

    assert Repo.exists?(
             from(j in Oban.Job,
               where: fragment("?->>'artifact_id'", j.args) == ^artifact.id and j.queue == "media"
             )
           )

    assert {:ok, :provider_updated} = process(artifact.id)
    assert Repo.get!(Artifact, artifact.id).status == :stopping
  end

  test "verified callback is idempotent, rejects substitutions, and gates playback on pinned verification",
       context do
    enable!(context)
    artifact = start_recording!(context)
    row = Repo.get!(Artifact, artifact.id)
    raw = callback(row)
    assert {:error, :invalid_provider_webhook} = Artifacts.handle_callback(raw, "wrong-signature")

    assert {:error, :not_found} =
             Artifacts.handle_callback(
               callback(%{row | object_key: "other/tenant.mp4"}),
               "verified"
             )

    assert {:ok, :accepted} = Artifacts.handle_callback(raw, "verified")
    assert {:ok, :replayed} = Artifacts.handle_callback(raw, "verified")
    changed = Jason.decode!(raw) |> Map.put("byte_size", 8) |> Jason.encode!()
    assert {:error, :artifact_callback_conflict} = Artifacts.handle_callback(changed, "verified")

    assert {:error, :artifact_not_available} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               context.subject
             )

    assert {:ok, :verified} = process(artifact.id)

    assert {:ok, %{download: %{expires_in: 60}}} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               artifact.id,
               context.subject
             )

    assert Repo.get!(Artifact, artifact.id).object_version_id == "version-1"
  end

  test "transcripts are explicitly derived from the verified source and keep Restricted text out of metadata",
       context do
    enable!(context)
    recording = available_recording!(context)

    assert {:ok, transcript} =
             Artifacts.request(
               context.account.conversation.id,
               context.call.id,
               %{
                 kind: :transcript,
                 source_artifact_id: recording.id,
                 idempotency_key: "transcript-operation"
               },
               context.subject
             )

    assert transcript.status == :processing
    assert {:ok, :transcribed} = process(transcript.id)
    assert_received {:transcription_source, "version-1", _}

    assert {:ok, %{segments: [%ArtifactTranscriptSegment{text: "Meeting decision <script>"}]}} =
             Artifacts.transcript(
               context.account.conversation.id,
               context.call.id,
               transcript.id,
               context.subject
             )

    assert {:ok, page} =
             Artifacts.list(context.account.conversation.id, context.call.id, context.subject)

    refute inspect(page) =~ "Meeting decision"

    assert {:ok, _} =
             Artifacts.delete(
               context.account.conversation.id,
               context.call.id,
               transcript.id,
               context.subject
             )

    assert {:ok, :deleted} = process(transcript.id)
    refute Repo.exists?(from(s in Segment, where: s.artifact_id == ^transcript.id))
    assert Repo.get!(Artifact, recording.id).status == :available
  end

  test "cross tenant and revoked identities cannot list, play or read transcript content",
       context do
    enable!(context)
    recording = available_recording!(context)
    other = Fixtures.account_fixture()

    assert {:error, :not_found} =
             Artifacts.list(
               context.account.conversation.id,
               context.call.id,
               Fixtures.subject(other)
             )

    assert {:error, :forbidden} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               recording.id,
               Fixtures.subject(other)
             )

    refute_received {:object_downloaded, _}

    context.account.session
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :forbidden} =
             Artifacts.list(context.account.conversation.id, context.call.id, context.subject)

    assert {:error, :forbidden} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               recording.id,
               context.subject
             )

    refute_received {:object_downloaded, _}
  end

  test "legal holds block both requested purge and physical cleanup and retention hides expired retrieval",
       context do
    enable!(context)
    recording = available_recording!(context)
    hold_subject = Fixtures.step_up(context.account, context.subject)

    {:ok, _} =
      CommsCore.Governance.create_legal_hold(
        %{
          scope_type: :conversation,
          conversation_id: context.account.conversation.id,
          name: "Artifact preservation",
          reason: "Synthetic acceptance hold"
        },
        hold_subject
      )

    assert {:error, :artifact_legal_hold} =
             Artifacts.delete(
               context.account.conversation.id,
               context.call.id,
               recording.id,
               context.subject
             )

    Repo.get!(Artifact, recording.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, :idle} = process(recording.id)
    refute_received {:object_deleted, _}

    assert {:ok, %{artifacts: []}} =
             Artifacts.list(context.account.conversation.id, context.call.id, context.subject)

    assert {:error, :artifact_not_available} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               recording.id,
               context.subject
             )
  end

  test "current conversation membership is rechecked for artifact access", context do
    enable!(context)
    recording = available_recording!(context)
    member = signed_in_member(context.account)

    {:ok, membership} =
      Conversations.add_member(
        context.account.conversation.id,
        member.user.id,
        :member,
        context.subject
      )

    assert {:ok, _} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               recording.id,
               member.subject
             )

    {:ok, _} =
      Conversations.remove_member(
        context.account.conversation.id,
        member.user.id,
        %{reason: "Artifact revocation test", version: membership.lock_version},
        context.subject
      )

    assert {:error, :forbidden} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               recording.id,
               member.subject
             )
  end

  test "a permanently invalid transcription source records a terminal failure instead of remaining processing",
       context do
    enable!(context)
    recording = available_recording!(context)
    Application.put_env(:comms_core, :artifact_transcription_adapter, RejectedTranscription)

    assert {:ok, transcript} =
             Artifacts.request(
               context.account.conversation.id,
               context.call.id,
               %{
                 kind: :transcript,
                 source_artifact_id: recording.id,
                 idempotency_key: "transcript-invalid-source"
               },
               context.subject
             )

    assert {:ok, :transcription_failed} = process(transcript.id)
    row = Repo.get!(Artifact, transcript.id)
    assert row.status == :failed
    assert row.failure_code == "transcription_source_or_result_invalid"
    refute Repo.exists?(from(s in Segment, where: s.artifact_id == ^transcript.id))
  end

  test "transcription revalidates its requester's session before sending stored media", context do
    enable!(context)
    recording = available_recording!(context)
    {:ok, transcript} = request_transcript!(context, recording)

    Repo.get!(Accounts.Session, context.subject.session_id)
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, :transcription_cancelled} = process(transcript.id)
    refute_received {:transcription_source, _, _}
    assert Repo.get!(Artifact, transcript.id).status == :failed
    refute Repo.exists?(from(s in Segment, where: s.artifact_id == ^transcript.id))
  end

  test "expired terminal media is purged even when verification never qualified it", context do
    enable!(context)
    recording = start_recording!(context)
    {:ok, _} = Artifacts.handle_callback(callback(Repo.get!(Artifact, recording.id)), "verified")
    Application.put_env(:comms_core, :artifact_storage_adapter, UnverifiedStorage)
    assert {:error, :artifact_object_verification_failed} = process(recording.id)
    refute_received {:object_deleted, _}

    Repo.get!(Artifact, recording.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, :deleted} = process(recording.id)
    assert_received {:object_deleted, _}
    assert Repo.get!(Artifact, recording.id).status == :deleted
  end

  test "governance erasure hides content immediately and waits for verified source purge and transcript removal",
       context do
    enable!(context)
    recording = available_recording!(context)
    {:ok, transcript} = request_transcript!(context, recording)
    assert {:ok, :transcribed} = process(transcript.id)

    assert {:error, :transaction_required} =
             Artifacts.prepare_governance_erasure(
               context.account.tenant.id,
               :user,
               context.subject.user_id
             )

    assert {:ok, {:ok, plan}} =
             Repo.transaction(fn ->
               Artifacts.prepare_governance_erasure(
                 context.account.tenant.id,
                 :user,
                 context.subject.user_id
               )
             end)

    assert plan.pending_artifact_count == 2

    assert {:ok, true} =
             Artifacts.governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.subject.user_id
             )

    assert {:ok, %{artifacts: []}} =
             Artifacts.list(context.account.conversation.id, context.call.id, context.subject)

    assert {:error, :artifact_not_available} =
             Artifacts.playback(
               context.account.conversation.id,
               context.call.id,
               recording.id,
               context.subject
             )

    assert {:error, :artifact_not_available} =
             Artifacts.transcript(
               context.account.conversation.id,
               context.call.id,
               transcript.id,
               context.subject
             )

    assert {:ok, []} = Artifacts.search(context.subject, %{q: "Meeting decision"})

    Application.put_env(:comms_core, :artifact_storage_adapter, UnavailableDeletionStorage)
    assert {:error, :artifact_object_deletion_not_verified} = process(recording.id)

    assert {:ok, true} =
             Artifacts.governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.subject.user_id
             )

    Application.put_env(:comms_core, :artifact_storage_adapter, Storage)
    assert {:ok, :deleted} = process(recording.id)

    assert {:ok, true} =
             Artifacts.governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.subject.user_id
             )

    assert {:ok, :deleted} = process(transcript.id)
    refute Repo.exists?(from(s in Segment, where: s.artifact_id == ^transcript.id))

    assert {:ok, false} =
             Artifacts.governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.subject.user_id
             )
  end

  test "governance capture erasure waits for provider termination before purging a writable object",
       context do
    enable!(context)
    recording = start_recording!(context)

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               Artifacts.prepare_governance_erasure(
                 context.account.tenant.id,
                 :conversation,
                 context.account.conversation.id
               )
             end)

    assert {:ok, :provider_updated} = process(recording.id)
    assert_received {:provider_stopped, _}
    refute_received {:object_deleted, _}

    assert {:ok, true} =
             Artifacts.governance_erasure_pending?(
               context.account.tenant.id,
               :conversation,
               context.account.conversation.id
             )

    {:ok, _} = Artifacts.handle_callback(callback(Repo.get!(Artifact, recording.id)), "verified")
    assert {:ok, :deleted} = process(recording.id)
    assert_received {:object_deleted, _}

    assert {:ok, false} =
             Artifacts.governance_erasure_pending?(
               context.account.tenant.id,
               :conversation,
               context.account.conversation.id
             )
  end

  test "a legal hold refuses an entire governance artifact plan before any erasure flag is written",
       context do
    enable!(context)
    recording = available_recording!(context)
    hold_subject = Fixtures.step_up(context.account, context.subject)

    {:ok, _} =
      CommsCore.Governance.create_legal_hold(
        %{
          scope_type: :conversation,
          conversation_id: context.account.conversation.id,
          name: "Artifact erasure hold",
          reason: "Synthetic hold protection"
        },
        hold_subject
      )

    assert {:error, :artifact_legal_hold} =
             Repo.transaction(fn ->
               Artifacts.prepare_governance_erasure(
                 context.account.tenant.id,
                 :user,
                 context.subject.user_id
               )
             end)

    row = Repo.get!(Artifact, recording.id)
    assert is_nil(row.erasure_requested_at)
    assert row.status == :available
    refute_received {:object_deleted, _}
  end

  defp request_transcript!(c, recording),
    do:
      Artifacts.request(
        c.account.conversation.id,
        c.call.id,
        %{
          kind: :transcript,
          source_artifact_id: recording.id,
          idempotency_key: "transcript-operation"
        },
        c.subject
      )

  defp queued_recording!(c) do
    {:ok, artifact} = request(c)

    {:ok, _} =
      Artifacts.consent(c.account.conversation.id, c.call.id, artifact.id, true, c.subject)

    {:ok, _} = Artifacts.start(c.account.conversation.id, c.call.id, artifact.id, c.subject)
    artifact
  end

  defp request(c),
    do:
      Artifacts.request(
        c.account.conversation.id,
        c.call.id,
        %{idempotency_key: "recording-operation"},
        c.subject
      )

  defp process(id), do: Artifacts.process(id, RuntimePorts.job_worker!(:call_artifact))

  defp enable!(c),
    do:
      Application.put_env(:comms_core, :meeting_artifact_policy,
        privacy_approved: true,
        provider_qualified: true,
        enabled_tenant_ids: [c.account.tenant.id]
      )

  defp start_recording!(c) do
    {:ok, artifact} = request(c)

    {:ok, _} =
      Artifacts.consent(c.account.conversation.id, c.call.id, artifact.id, true, c.subject)

    {:ok, _} = Artifacts.start(c.account.conversation.id, c.call.id, artifact.id, c.subject)
    {:ok, _} = process(artifact.id)
    artifact
  end

  defp available_recording!(c) do
    artifact = start_recording!(c)
    {:ok, _} = Artifacts.handle_callback(callback(Repo.get!(Artifact, artifact.id)), "verified")
    {:ok, _} = process(artifact.id)
    artifact
  end

  defp callback(a),
    do:
      Jason.encode!(%{
        event_id: "event-" <> a.id,
        provider_job_id: a.provider_job_id,
        provider_room: a.provider_room,
        object_key: a.object_key,
        byte_size: 4
      })

  defp admit!(conversation_id, call_id, subject) do
    {:ok, _, _} =
      AudioCalls.with_join_authorized(conversation_id, call_id, subject, fn request ->
        {:ok, request.provider_identity}
      end)
  end

  defp signed_in_member(account) do
    member = Fixtures.user_fixture(account)

    suffix =
      member.user.email |> String.split("@") |> hd() |> String.replace_prefix("member-", "")

    {:ok, signed_in} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Artifact browser", platform: "test"}
      )

    {:ok, access} = Accounts.access_context(signed_in.session_id)
    %{user: signed_in.user, subject: access.subject}
  end
end
