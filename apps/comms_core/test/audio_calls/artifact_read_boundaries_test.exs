defmodule CommsCore.AudioCalls.ArtifactReadBoundariesTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Accounts, AudioCalls, Conversations, Governance, Repo, RuntimePorts}
  alias CommsCore.Accounts.Session
  alias CommsCore.AudioCalls.{Artifacts, ArtifactSummaryReceipt}
  alias CommsCore.AudioCalls.Artifacts.{Artifact, Consent, Segment, Summary}
  alias CommsTestSupport.Fixtures

  defmodule Capture do
    def configured?(), do: true
    def start(_), do: {:error, :synthetic_capture_not_invoked}
    def stop(_), do: {:error, :synthetic_capture_not_invoked}
    def reconcile(_), do: {:error, :synthetic_capture_not_invoked}
    def verify_callback(_, _), do: {:error, :synthetic_capture_not_invoked}
  end

  defmodule Storage do
    def verify(_), do: {:error, :synthetic_verification_not_invoked}
    def delete(_), do: {:error, :synthetic_deletion_not_invoked}

    def download(object) do
      send(self(), {:synthetic_private_download, object.object_key})
      Process.sleep(Application.get_env(:comms_core, :synthetic_read_delay, 0))

      {:ok,
       %{
         url: "https://storage.example.test/approved",
         approved_origin: "https://storage.example.test",
         expires_in: 60
       }}
    end
  end

  defmodule Quotes do
    def configured?(), do: true

    def summarize(request) do
      send(self(), :synthetic_quotes_called)

      {:ok,
       %ArtifactSummaryReceipt{
         provider_id: "synthetic-quotes",
         model: "extractive-quotes-v1",
         source_sha256: request.source_sha256,
         text: request.text
       }}
    end
  end

  setup do
    settings = [
      meeting_artifact_policy: [],
      artifact_provider_adapter: Capture,
      artifact_storage_adapter: Storage,
      artifact_summarization_adapter: Quotes,
      synthetic_read_delay: 0
    ]

    old = Map.new(settings, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)
    Enum.each(settings, fn {key, val} -> Application.put_env(:comms_core, key, val) end)

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    Application.put_env(:comms_core, :meeting_artifact_policy,
      privacy_approved: true,
      provider_qualified: true,
      summary_privacy_approved: true,
      enabled_tenant_ids: [account.tenant.id]
    )

    {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    {:ok, _, _} = admit_reader(account.conversation.id, call.id, subject)
    %{account: account, subject: subject, call: call}
  end

  test "a valid fresh reader retains normal ended-call source authority and SQL substring semantics",
       c do
    {recording, transcript} = retained_source(c)
    reader = fresh_owner(c)
    assert {:ok, _} = Accounts.access_grant(reader)
    assert {:ok, %{segments: [segment]}} = read_transcript(c, transcript, reader)
    assert segment.text == "Decision 100%_complete Friday."
    assert {:ok, %{download: %{expires_in: 60}}} = playback(c, recording, reader)
    assert_received {:synthetic_private_download, _}
    assert {:ok, [result]} = Artifacts.search(reader, %{q: "100%_c", limit: 1})
    assert result.id == transcript.id
    assert {:ok, [result]} = Artifacts.search(reader, %{q: "TRANSCRIPT"})
    assert result.id == transcript.id
  end

  test "a real second current session cannot accept the original capture summary admission", c do
    recording = request_recording(c)
    reader = fresh_owner(c)
    assert {:ok, _} = Accounts.access_grant(reader)
    assert {:error, :forbidden} = summary_consent(c, recording, reader)
    consent = Repo.get_by!(Consent, artifact_id: recording.id)
    refute consent.summary_accepted
    assert is_nil(consent.summary_decided_at)
  end

  test "foreign and revoked current readers remain forbidden while the original reader stays valid",
       c do
    {recording, transcript} = retained_source(c)
    foreign = Fixtures.account_fixture() |> Fixtures.subject()
    assert {:error, :forbidden} = read_transcript(c, transcript, foreign)
    assert {:error, :forbidden} = playback(c, recording, foreign)
    reader = fresh_owner(c)
    assert :ok = Accounts.revoke_session(reader.session_id, reader.user_id)
    assert {:error, :forbidden} = read_transcript(c, transcript, reader)
    assert {:error, :forbidden} = playback(c, recording, reader)
    assert {:error, :forbidden} = Artifacts.search(reader, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
    assert {:ok, %{segments: [_]}} = read_transcript(c, transcript, c.subject)
  end

  test "a real rejoined admission cannot replace the revoked original capture grant", c do
    {recording, transcript} = retained_source(c, false)
    reader = fresh_owner(c)
    assert :ok = Accounts.revoke_session(c.subject.session_id, c.subject.user_id)
    assert {:ok, _, _} = admit_reader(c.account.conversation.id, c.call.id, reader)
    end_call(c, reader)
    assert {:ok, _} = Accounts.access_grant(reader)
    assert {:error, :forbidden} = read_transcript(c, transcript, reader)
    assert {:error, :forbidden} = playback(c, recording, reader)
    assert {:ok, []} = Artifacts.search(reader, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
  end

  test "a different current member cannot read captured content after its original session is revoked",
       c do
    {recording, transcript} = retained_source(c)
    reader = member_reader(c)
    assert :ok = Accounts.revoke_session(c.subject.session_id, c.subject.user_id)
    assert {:ok, _} = Accounts.access_grant(reader)
    assert {:error, :forbidden} = read_transcript(c, transcript, reader)
    assert {:error, :forbidden} = playback(c, recording, reader)
    assert {:ok, []} = Artifacts.search(reader, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
  end

  test "an expired original session is not substituted by a valid current reader", c do
    {recording, transcript} = retained_source(c)
    reader = fresh_owner(c)

    Repo.get!(Session, c.subject.session_id)
    |> change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, _} = Accounts.access_grant(reader)
    assert {:error, :forbidden} = read_transcript(c, transcript, reader)
    assert {:error, :forbidden} = playback(c, recording, reader)
    assert {:ok, []} = Artifacts.search(reader, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
  end

  test "source expiry hides a still-available longer-lived derived transcript and its search matches",
       c do
    {recording, transcript} = retained_source(c)

    recording
    |> change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert Repo.get!(Artifact, transcript.id).status == :available
    assert {:error, :artifact_not_available} = read_transcript(c, transcript, c.subject)
    assert {:error, :artifact_not_available} = playback(c, recording, c.subject)
    assert {:ok, []} = Artifacts.search(c.subject, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
  end

  test "an unavailable source cannot expose remaining derived text or its metadata match", c do
    {recording, transcript} = retained_source(c)
    recording |> change(status: :deleting) |> Repo.update!()
    assert {:error, :artifact_not_available} = read_transcript(c, transcript, c.subject)
    assert {:error, :artifact_not_available} = playback(c, recording, c.subject)
    assert {:ok, []} = Artifacts.search(c.subject, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
  end

  test "ordinary recording consent remains required for retained reads", c do
    {recording, transcript} = retained_source(c)
    Repo.get_by!(Consent, artifact_id: recording.id) |> change(accepted: false) |> Repo.update!()
    assert {:error, :recording_consent_required} = read_transcript(c, transcript, c.subject)
    assert {:error, :recording_consent_required} = playback(c, recording, c.subject)
    assert {:ok, []} = Artifacts.search(c.subject, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
  end

  test "approved Governance erasure closes source reads before asynchronous artifact flags change",
       c do
    {recording, transcript} = retained_source(c)
    admin = Fixtures.step_up(c.account)

    {:ok, %{request: request}} =
      Governance.create_deletion_request(
        %{
          target_type: "conversation",
          conversation_id: c.account.conversation.id,
          reason: "Synthetic source-boundary erasure"
        },
        admin
      )

    {:ok, _} =
      Governance.transition_deletion_request(
        request.id,
        %{
          version: request.lock_version,
          status: "approved",
          transition_reason: "Synthetic source verified"
        },
        admin
      )

    assert is_nil(Repo.get!(Artifact, transcript.id).erasure_requested_at)
    assert {:error, :artifact_erasure_pending} = read_transcript(c, transcript, c.subject)
    assert {:error, :artifact_erasure_pending} = playback(c, recording, c.subject)
    assert {:ok, []} = Artifacts.search(c.subject, %{q: "Friday"})
    refute_received {:synthetic_private_download, _}
  end

  test "source expiry during private download refuses the returned URL", c do
    {recording, _transcript} = retained_source(c)

    recording
    |> change(expires_at: DateTime.add(DateTime.utc_now(), 1, :second))
    |> Repo.update!()

    Application.put_env(:comms_core, :synthetic_read_delay, 1_100)
    assert {:error, :artifact_not_available} = playback(c, recording, c.subject)
    assert_received {:synthetic_private_download, _}
  end

  test "recording UUID as summary source is refused before any artifact, claim, job or provider effect",
       c do
    {recording, _transcript} = retained_source(c)
    before = inventory(c)
    assert {:error, :artifact_not_available} = request_summary(c, recording.id)
    assert inventory(c) == before
    refute_received :synthetic_quotes_called
  end

  test "an existing summary UUID cannot be substituted for its transcript source", c do
    {_recording, transcript} = retained_source(c)
    {:ok, summary} = request_summary(c, transcript.id)
    before = inventory(c)
    assert {:error, :artifact_not_available} = request_summary(c, summary.id)
    assert inventory(c) == before
    assert is_nil(Repo.get!(Artifact, summary.id).summary_provider_claimed_at)
    refute_received :synthetic_quotes_called
  end

  test "retained summary retrieval detects source segment mutation after a valid receipt", c do
    {_recording, transcript} = retained_source(c)
    {:ok, summary} = request_summary(c, transcript.id)

    assert {:ok, :summarized} =
             Artifacts.process(summary.id, RuntimePorts.job_worker!(:call_summary))

    assert_received :synthetic_quotes_called

    assert {:ok, _} =
             AudioCalls.artifact_summary(
               c.account.conversation.id,
               c.call.id,
               summary.id,
               c.subject
             )

    Repo.get_by!(Segment, artifact_id: transcript.id)
    |> change(text: "A different retained source line.")
    |> Repo.update!()

    assert {:error, :summary_source_changed} =
             AudioCalls.artifact_summary(
               c.account.conversation.id,
               c.call.id,
               summary.id,
               c.subject
             )

    assert Repo.aggregate(from(s in Summary, where: s.artifact_id == ^summary.id), :count) == 1
    refute_received :synthetic_quotes_called
  end

  defp request_recording(c) do
    {:ok, view} =
      Artifacts.request(
        c.account.conversation.id,
        c.call.id,
        %{summary_requested: true, idempotency_key: "read-boundary-recording"},
        c.subject
      )

    Repo.get!(Artifact, view.id)
  end

  defp retained_source(c, ended \\ true) do
    recording = request_recording(c)

    {:ok, _} =
      Artifacts.consent(c.account.conversation.id, c.call.id, recording.id, true, c.subject)

    {:ok, _} = summary_consent(c, recording, c.subject)
    # Independently verified upstream recording state; this file exercises the
    # actual owner admission/read boundaries rather than simulating a carrier.
    recording =
      recording
      |> Artifact.changeset(%{
        status: :available,
        byte_size: 4,
        object_version_id: "synthetic-version",
        object_etag: "synthetic-etag",
        checksum_sha256: String.duplicate("a", 64)
      })
      |> Repo.update!()

    transcript =
      %Artifact{}
      |> Artifact.changeset(%{
        tenant_id: recording.tenant_id,
        conversation_id: recording.conversation_id,
        call_id: recording.call_id,
        source_artifact_id: recording.id,
        requested_by_user_id: c.subject.user_id,
        requested_by_device_id: c.subject.device_id,
        requested_by_session_id: c.subject.session_id,
        kind: :transcript,
        status: :available,
        provider_room: recording.provider_room,
        object_key: "synthetic-read-transcript.json",
        content_type: "application/json",
        expires_at: recording.expires_at,
        idempotency_key: "read-boundary-transcript",
        summary_requested: true
      })
      |> Repo.insert!()

    %Segment{}
    |> Segment.changeset(%{
      tenant_id: transcript.tenant_id,
      artifact_id: transcript.id,
      sequence: 0,
      start_ms: 0,
      end_ms: 1_000,
      text: "Decision 100%_complete Friday."
    })
    |> Repo.insert!()

    if ended, do: end_call(c, c.subject)
    {recording, transcript}
  end

  defp admit_reader(conversation, call, subject),
    do:
      AudioCalls.with_join_authorized(conversation, call, subject, fn request ->
        {:ok, request.provider_identity}
      end)

  defp end_call(c, subject),
    do:
      AudioCalls.end_call(
        c.account.conversation.id,
        c.call.id,
        %{reason: "owner_ended"},
        subject,
        fn _ -> :ok end
      )

  defp read_transcript(c, artifact, subject),
    do: AudioCalls.artifact_transcript(c.account.conversation.id, c.call.id, artifact.id, subject)

  defp playback(c, artifact, subject),
    do: Artifacts.playback(c.account.conversation.id, c.call.id, artifact.id, subject)

  defp summary_consent(c, artifact, subject),
    do:
      AudioCalls.consent_artifact_summary(
        c.account.conversation.id,
        c.call.id,
        artifact.id,
        %{accepted: true, policy_version: "meeting-summary-v1"},
        subject
      )

  defp request_summary(c, source),
    do:
      Artifacts.request(
        c.account.conversation.id,
        c.call.id,
        %{kind: :summary, source_artifact_id: source, idempotency_key: "read-boundary-summary"},
        c.subject
      )

  defp fresh_owner(c) do
    suffix = c.account.tenant.slug |> String.split("-") |> List.last()
    authenticate(c.account.tenant.slug, c.account.user.email, suffix)
  end

  defp member_reader(c) do
    member = Fixtures.user_fixture(c.account).user
    [local, _] = String.split(member.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")

    {:ok, _} =
      Conversations.add_member(
        c.account.conversation.id,
        member.id,
        :member,
        Fixtures.step_up(c.account)
      )

    authenticate(c.account.tenant.slug, member.email, suffix)
  end

  defp authenticate(tenant, email, suffix) do
    {:ok, auth} =
      Accounts.authenticate_view(tenant, email, "correct-horse-battery-#{suffix}", %{
        name: "Synthetic fresh reader",
        platform: "test"
      })

    {:ok, context} = Accounts.access_context(auth.session_id)
    context.subject
  end

  defp inventory(c) do
    %{
      artifacts:
        Repo.aggregate(from(a in Artifact, where: a.tenant_id == ^c.account.tenant.id), :count),
      summaries:
        Repo.aggregate(from(s in Summary, where: s.tenant_id == ^c.account.tenant.id), :count),
      jobs:
        Repo.aggregate(
          from(j in Oban.Job, where: j.worker == "CommsWorkers.CallSummaryWorker"),
          :count
        ),
      claims:
        Repo.aggregate(
          from(a in Artifact,
            where:
              a.tenant_id == ^c.account.tenant.id and not is_nil(a.summary_provider_claimed_at)
          ),
          :count
        )
    }
  end
end
