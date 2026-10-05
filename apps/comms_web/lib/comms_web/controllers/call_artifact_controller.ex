defmodule CommsWeb.CallArtifactController do
  use CommsWeb, :controller
  alias CommsCore.AudioCalls
  plug(CommsWeb.Plugs.RequireSecureTransport)

  def index(conn, %{"conversation_id" => conversation_id, "call_id" => call_id}) do
    with {:ok, result} <-
           AudioCalls.list_artifacts(conversation_id, call_id, conn.assigns.current_subject) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{data: Enum.map(result.artifacts, &present/1), capabilities: result.capabilities})
    else
      {:error, reason} -> artifact_error(conn, reason)
    end
  end

  def create(conn, %{"conversation_id" => conversation_id, "call_id" => call_id} = params) do
    respond(
      conn,
      AudioCalls.request_artifact(conversation_id, call_id, params, conn.assigns.current_subject),
      :created
    )
  end

  def consent(conn, %{
        "conversation_id" => conversation_id,
        "call_id" => call_id,
        "id" => id,
        "accepted" => accepted
      })
      when is_boolean(accepted) do
    respond(
      conn,
      AudioCalls.consent_artifact(
        conversation_id,
        call_id,
        id,
        accepted,
        conn.assigns.current_subject
      )
    )
  end

  def consent(conn, _), do: artifact_error(conn, :invalid_artifact_consent)

  def summary_consent(
        conn,
        %{"conversation_id" => conversation_id, "call_id" => call_id, "id" => id} = params
      ) do
    respond(
      conn,
      AudioCalls.consent_artifact_summary(
        conversation_id,
        call_id,
        id,
        params,
        conn.assigns.current_subject
      )
    )
  end

  def summary(conn, %{"conversation_id" => conversation_id, "call_id" => call_id, "id" => id}) do
    with {:ok, result} <-
           AudioCalls.artifact_summary(conversation_id, call_id, id, conn.assigns.current_subject) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{data: present(result.artifact), summary: Map.from_struct(result.summary)})
    else
      {:error, reason} -> artifact_error(conn, reason)
    end
  end

  def start(conn, %{"conversation_id" => conversation_id, "call_id" => call_id, "id" => id}) do
    respond(
      conn,
      AudioCalls.start_artifact(conversation_id, call_id, id, conn.assigns.current_subject),
      :accepted
    )
  end

  def stop(conn, %{"conversation_id" => conversation_id, "call_id" => call_id, "id" => id}) do
    respond(
      conn,
      AudioCalls.stop_artifact(conversation_id, call_id, id, conn.assigns.current_subject),
      :accepted
    )
  end

  def delete(conn, %{"conversation_id" => conversation_id, "call_id" => call_id, "id" => id}) do
    respond(
      conn,
      AudioCalls.delete_artifact(conversation_id, call_id, id, conn.assigns.current_subject),
      :accepted
    )
  end

  def playback(conn, %{"conversation_id" => conversation_id, "call_id" => call_id, "id" => id}) do
    with {:ok, result} <-
           AudioCalls.artifact_playback(
             conversation_id,
             call_id,
             id,
             conn.assigns.current_subject
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{data: present(result.artifact), download: result.download})
    else
      {:error, reason} -> artifact_error(conn, reason)
    end
  end

  def transcript(conn, %{"conversation_id" => conversation_id, "call_id" => call_id, "id" => id}) do
    with {:ok, result} <-
           AudioCalls.artifact_transcript(
             conversation_id,
             call_id,
             id,
             conn.assigns.current_subject
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        data: present(result.artifact),
        segments: Enum.map(result.segments, &Map.from_struct/1)
      })
    else
      {:error, reason} -> artifact_error(conn, reason)
    end
  end

  defp respond(conn, result, status \\ :ok)

  defp respond(conn, {:ok, artifact}, status),
    do:
      conn
      |> put_status(status)
      |> put_resp_header("cache-control", "no-store")
      |> json(%{data: present(artifact)})

  defp respond(conn, {:error, reason}, _), do: artifact_error(conn, reason)
  defp present(artifact), do: Map.from_struct(artifact)

  defp artifact_error(conn, reason) do
    {status, detail} =
      case reason do
        :summarization_unavailable ->
          {409,
           "Summary generation requires separate privacy approval and qualified local processing."}

        :summary_consent_required ->
          {409,
           "Every original capture admission must separately consent to selected-quote summaries."}

        :summary_post_call_only ->
          {409, "Summaries are available only after the call ends."}

        :summary_not_disclosed ->
          {409, "Summaries were not disclosed when recording was requested."}

        :invalid_summary_consent ->
          {422, "Choose explicit summary consent using the disclosed meeting-summary-v1 policy."}

        :summary_source_too_large ->
          {409, "This transcript exceeds the approved summary processing limit."}

        :summary_source_changed ->
          {409, "The retained source transcript proof changed."}

        :idempotency_conflict ->
          {409, "This request identifier belongs to another artifact decision."}

        :recording_disabled ->
          {403, "Recording requires workspace privacy approval and qualified provider opt-in."}

        :recording_requires_livekit ->
          {409,
           "Recording requires LiveKit transport. Direct audio must be disabled by the workspace operator."}

        :artifact_provider_unavailable ->
          {503, "Recording provider is unavailable."}

        :artifact_storage_unavailable ->
          {503, "Artifact storage is unavailable."}

        :recording_consent_required ->
          {409, "Every admitted participant must explicitly consent before recording starts."}

        :recording_consent_admission_blocked ->
          {409, "Stop the recording before admitting a new participant."}

        :artifact_legal_hold ->
          {409, "A legal hold prevents deletion."}

        :artifact_not_available ->
          {409, "This artifact is unavailable or has expired."}

        :transcription_unavailable ->
          {409, "Persistent transcription has no qualified provider."}

        :recording_must_stop_before_deletion ->
          {409, "Stop recording before deleting the artifact."}

        :artifact_erasure_pending ->
          {409, "Meeting artifacts cannot be created while relevant data erasure is pending."}

        :artifact_processing ->
          {409, "The artifact is still being verified."}

        :recording_requires_admission ->
          {409, "Join the call before requesting recording."}

        :idempotency_key_required ->
          {422, "A valid request identifier is required."}

        :invalid_artifact_consent ->
          {422, "Choose whether to consent to recording."}

        :artifact_not_startable ->
          {409, "This recording cannot be started."}

        :artifact_not_capturing ->
          {409, "This recording is no longer accepting consent."}

        _ ->
          {nil, nil}
      end

    if status,
      do:
        conn |> put_status(status) |> json(%{error: %{code: to_string(reason), detail: detail}}),
      else: CommsWeb.FallbackController.call(conn, {:error, reason})
  end
end
