defmodule CommsCore.AudioCalls.RecognitionSummariesTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Accounts, AudioCalls, Repo, RuntimePorts}
  alias CommsCore.AudioCalls.{Artifacts, ArtifactSummaryReceipt}
  alias CommsCore.AudioCalls.Artifacts.{Artifact, Consent, Segment, Summary}
  alias CommsTestSupport.Fixtures

  defmodule SyntheticSummary do
    def configured?(), do: true

    def summarize(request) do
      send(self(), {:synthetic_summary_called, request.source_sha256})

      case Application.get_env(:comms_core, :synthetic_summary_result, :ok) do
        :timeout ->
          {:error, :outbound_timeout}

        :paused ->
          send(
            Application.fetch_env!(:comms_core, :synthetic_summary_test_pid),
            {:synthetic_summary_effect_started, self()}
          )

          receive do
            :finish_summary_effect ->
              {:ok,
               %ArtifactSummaryReceipt{
                 provider_id: "synthetic",
                 model: "extractive-quotes-v1",
                 source_sha256: request.source_sha256,
                 text: request.text
               }}
          after
            3_000 -> {:error, :outbound_timeout}
          end

        :invalid_lineage ->
          {:ok,
           %ArtifactSummaryReceipt{
             provider_id: "synthetic",
             model: "extractive-quotes-v1",
             source_sha256: String.duplicate("b", 64),
             text: request.text
           }}

        :ok ->
          {:ok,
           %ArtifactSummaryReceipt{
             provider_id: "synthetic",
             model: "extractive-quotes-v1",
             source_sha256: request.source_sha256,
             text: request.text
           }}
      end
    end
  end

  setup do
    keys = [
      :meeting_artifact_policy,
      :artifact_summarization_adapter,
      :artifact_provider_adapter,
      :synthetic_summary_result,
      :synthetic_summary_test_pid
    ]

    old = Map.new(keys, &{&1, Application.fetch_env(:comms_core, &1)})

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    {:ok, _, _} =
      AudioCalls.with_join_authorized(account.conversation.id, call.id, subject, fn request ->
        {:ok, request.provider_identity}
      end)

    Application.put_env(:comms_core, :meeting_artifact_policy,
      privacy_approved: true,
      provider_qualified: true,
      summary_privacy_approved: true,
      enabled_tenant_ids: [account.tenant.id]
    )

    Application.put_env(:comms_core, :artifact_summarization_adapter, SyntheticSummary)
    Application.put_env(:comms_core, :artifact_provider_adapter, EnabledCapture)
    Application.put_env(:comms_core, :synthetic_summary_result, :ok)
    %{account: account, subject: subject, call: call}
  end

  defmodule EnabledCapture do
    def configured?(), do: true
    def start(_), do: {:error, :synthetic_capture_not_invoked}
    def stop(_), do: {:error, :synthetic_capture_not_invoked}
    def reconcile(_), do: {:error, :synthetic_capture_not_invoked}
    def verify_callback(_, _), do: {:error, :synthetic_capture_not_invoked}
  end

  test "ordinary recording consent cannot satisfy separately disclosed summary consent", c do
    recording = request_recording!(c)

    assert {:ok, _} =
             Artifacts.consent(
               c.account.conversation.id,
               c.call.id,
               recording.id,
               true,
               c.subject
             )

    assert {:error, :recording_consent_required} =
             Artifacts.start(c.account.conversation.id, c.call.id, recording.id, c.subject)

    assert {:error, :invalid_summary_consent} =
             AudioCalls.consent_artifact_summary(
               c.account.conversation.id,
               c.call.id,
               recording.id,
               %{accepted: true, policy_version: "ordinary-recording"},
               c.subject
             )

    assert {:ok, view} = consent_summary(c, recording.id, true)
    assert view.summary_consent_accepted_count == 1
    assert view.my_summary_consent
  end

  test "a rejoined or substituted session never accepts an original admission", c do
    recording = request_recording!(c)

    assert {:error, :forbidden} =
             consent_summary(
               %{c | subject: %{c.subject | session_id: Ecto.UUID.generate()}},
               recording.id,
               true
             )

    row = Repo.get_by!(Consent, artifact_id: recording.id)
    refute row.summary_accepted
    assert is_nil(row.summary_decided_at)
  end

  test "separate tenant privacy approval defaults closed even with an adapter", c do
    Application.put_env(:comms_core, :meeting_artifact_policy,
      privacy_approved: true,
      provider_qualified: true,
      enabled_tenant_ids: [c.account.tenant.id]
    )

    assert {:error, :summarization_unavailable} =
             Artifacts.request(
               c.account.conversation.id,
               c.call.id,
               %{kind: :recording, summary_requested: true, idempotency_key: "privacy-operation"},
               c.subject
             )

    refute_received {:synthetic_summary_called, _}
  end

  test "post-call summary persists exact source lineage and never outlives its source", c do
    {recording, transcript} = retained_source!(c)
    assert {:ok, view} = request_summary(c, transcript.id)
    assert view.kind == :summary
    assert {:ok, :summarized} = process_summary(view.id)
    assert_received {:synthetic_summary_called, digest}

    assert {:ok, result} =
             AudioCalls.artifact_summary(c.account.conversation.id, c.call.id, view.id, c.subject)

    assert result.summary.source_artifact_id == transcript.id
    assert result.summary.source_sha256 == digest
    assert result.summary.method == "extractive_quotes"
    assert result.summary.text == "We agreed to deliver Friday."

    assert result.summary.summary_sha256 ==
             Base.encode16(:crypto.hash(:sha256, result.summary.text), case: :lower)

    assert DateTime.compare(result.artifact.expires_at, recording.expires_at) != :gt
  end

  test "unknown provider outcome consumes its claim and another key cannot replay", c do
    {_recording, transcript} = retained_source!(c)
    Application.put_env(:comms_core, :synthetic_summary_result, :timeout)
    assert {:ok, view} = request_summary(c, transcript.id)
    assert {:ok, :summary_failed} = process_summary(view.id)
    assert_received {:synthetic_summary_called, _}
    assert {:ok, :idle} = process_summary(view.id)
    assert {:ok, replay} = request_summary(c, transcript.id, "different-summary-key")
    assert replay.id == view.id
    assert Repo.get!(Artifact, view.id).summary_provider_claimed_at
    refute_received {:synthetic_summary_called, _}
    refute Repo.exists?(from(s in Summary, where: s.artifact_id == ^view.id))
  end

  test "a wrong-lineage receipt produces no retained content and cannot be retried", c do
    {_recording, transcript} = retained_source!(c)
    Application.put_env(:comms_core, :synthetic_summary_result, :invalid_lineage)
    {:ok, view} = request_summary(c, transcript.id)
    assert {:ok, :summary_failed} = process_summary(view.id)
    assert_received {:synthetic_summary_called, _}
    assert {:ok, :idle} = process_summary(view.id)
    refute_received {:synthetic_summary_called, _}
    refute Repo.exists?(from(s in Summary, where: s.artifact_id == ^view.id))
  end

  @tag :concurrency
  test "session revocation waits for the retained effect boundary then closes retrieval", c do
    {_recording, transcript} = retained_source!(c)
    {:ok, view} = request_summary(c, transcript.id)
    Application.put_env(:comms_core, :synthetic_summary_result, :paused)
    Application.put_env(:comms_core, :synthetic_summary_test_pid, self())
    producer = Task.async(fn -> process_summary(view.id) end)
    assert_receive {:synthetic_summary_effect_started, effect_pid}
    test_pid = self()

    revoker =
      Task.async(fn ->
        result = Accounts.revoke_session(c.subject.session_id, c.subject.user_id)
        send(test_pid, :summary_session_revoked)
        result
      end)

    refute_receive :summary_session_revoked, 100
    send(effect_pid, :finish_summary_effect)
    assert {:ok, :summarized} = Task.await(producer, 5_000)
    assert {:ok, _} = Task.await(revoker, 5_000)

    assert {:error, :forbidden} =
             AudioCalls.artifact_summary(c.account.conversation.id, c.call.id, view.id, c.subject)
  end

  @tag :concurrency
  test "a competing reconciliation cannot invalidate a legitimate in-flight consumed claim", c do
    {_recording, transcript} = retained_source!(c)
    {:ok, view} = request_summary(c, transcript.id)
    Application.put_env(:comms_core, :synthetic_summary_result, :paused)
    Application.put_env(:comms_core, :synthetic_summary_test_pid, self())
    producer = Task.async(fn -> process_summary(view.id) end)
    assert_receive {:synthetic_summary_effect_started, effect_pid}
    observer = Task.async(fn -> process_summary(view.id) end)
    send(effect_pid, :finish_summary_effect)
    assert {:ok, :summarized} = Task.await(producer, 5_000)
    assert {:ok, :idle} = Task.await(observer, 5_000)
    assert Repo.get!(Artifact, view.id).status == :available
    assert Repo.aggregate(from(s in Summary, where: s.artifact_id == ^view.id), :count, :id) == 1
  end

  test "read-only reconciliation preserves a legitimate consumed in-flight claim", c do
    {_recording, transcript} = retained_source!(c)
    {:ok, view} = request_summary(c, transcript.id)
    row = Repo.get!(Artifact, view.id)

    row
    |> Artifact.changeset(%{
      summary_provider_claimed_at: DateTime.utc_now(),
      summary_effect_started_at: DateTime.utc_now(),
      summary_claim_fingerprint: String.duplicate("a", 64)
    })
    |> Repo.update!()

    assert {:ok, :claimed} = process_summary(view.id)
    assert Repo.get!(Artifact, view.id).status == :processing
    refute_received {:synthetic_summary_called, _}
  end

  test "withdrawal clears derived access immediately and physically erases summary content", c do
    {recording, transcript} = retained_source!(c)
    {:ok, view} = request_summary(c, transcript.id)
    assert {:ok, :summarized} = process_summary(view.id)
    assert {:ok, _} = consent_summary(c, recording.id, false)

    assert {:error, :summary_consent_required} =
             AudioCalls.artifact_summary(c.account.conversation.id, c.call.id, view.id, c.subject)

    assert {:ok, :deleted} = process_summary(view.id)
    refute Repo.exists?(from(s in Summary, where: s.artifact_id == ^view.id))
    assert AudioCalls.rollback_recognition_summary_hazard_count() > 0
  end

  test "retained session revocation fences summary production before any effect", c do
    {_recording, transcript} = retained_source!(c)
    {:ok, view} = request_summary(c, transcript.id)
    assert {:ok, _} = Accounts.revoke_session(c.subject.session_id, c.subject.user_id)
    assert {:error, :forbidden} = process_summary(view.id)
    refute_received {:synthetic_summary_called, _}
    refute Repo.exists?(from(s in Summary, where: s.artifact_id == ^view.id))
  end

  test "legal hold preserves content after consent withdrawal while retrieval stays closed", c do
    {recording, transcript} = retained_source!(c)
    {:ok, view} = request_summary(c, transcript.id)
    assert {:ok, :summarized} = process_summary(view.id)

    assert {:ok, _} =
             CommsCore.Governance.create_legal_hold(
               %{
                 scope_type: :conversation,
                 conversation_id: c.account.conversation.id,
                 name: "Synthetic summary hold",
                 reason: "Retained content qualification"
               },
               Fixtures.step_up(c.account, c.subject)
             )

    assert {:ok, _} = consent_summary(c, recording.id, false)
    assert {:error, :artifact_legal_hold} = process_summary(view.id)
    assert Repo.exists?(from(s in Summary, where: s.artifact_id == ^view.id))

    assert {:error, :summary_consent_required} =
             AudioCalls.artifact_summary(c.account.conversation.id, c.call.id, view.id, c.subject)
  end

  defp request_recording!(c) do
    {:ok, view} =
      Artifacts.request(
        c.account.conversation.id,
        c.call.id,
        %{summary_requested: true, idempotency_key: "disclosed-summary-capture"},
        c.subject
      )

    Repo.get!(Artifact, view.id)
  end

  defp retained_source!(c) do
    recording = request_recording!(c)

    {:ok, _} =
      Artifacts.consent(c.account.conversation.id, c.call.id, recording.id, true, c.subject)

    {:ok, _} = consent_summary(c, recording.id, true)
    # Synthetic owned fixture represents upstream independently verified media;
    # existing artifact provider/storage tests cover that actual adapter boundary.
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

    id = Ecto.UUID.generate()

    transcript =
      %Artifact{id: id}
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
        object_key: "synthetic-transcript.json",
        content_type: "application/json",
        expires_at: recording.expires_at,
        idempotency_key: "synthetic-retained-transcript",
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
      text: "We agreed to deliver Friday."
    })
    |> Repo.insert!()

    {:ok, _} =
      AudioCalls.end_call(
        c.account.conversation.id,
        c.call.id,
        %{reason: "owner_ended"},
        c.subject,
        fn _ -> :ok end
      )

    {recording, transcript}
  end

  defp consent_summary(c, id, accepted),
    do:
      AudioCalls.consent_artifact_summary(
        c.account.conversation.id,
        c.call.id,
        id,
        %{accepted: accepted, policy_version: "meeting-summary-v1"},
        c.subject
      )

  defp request_summary(c, source, key \\ "summary-operation"),
    do:
      Artifacts.request(
        c.account.conversation.id,
        c.call.id,
        %{kind: :summary, source_artifact_id: source, idempotency_key: key},
        c.subject
      )

  defp process_summary(id), do: Artifacts.process(id, RuntimePorts.job_worker!(:call_summary))
end
