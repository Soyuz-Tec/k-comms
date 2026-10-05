defmodule CommsCore.AudioCalls.ArtifactTranscriptionPort do
  @moduledoc "Calls-owned port for an explicit approved transcription service."
  alias CommsCore.AudioCalls.{
    ArtifactTranscriptionRequest,
    ArtifactTranscript,
    ArtifactTranscriptSegment
  }

  @spec configured?() :: boolean()
  def configured?() do
    case adapter() do
      {:ok, adapter} -> adapter.configured?()
      _ -> false
    end
  end

  @spec transcribe(ArtifactTranscriptionRequest.t()) ::
          {:ok, ArtifactTranscript.t()} | {:error, atom()}
  def transcribe(%ArtifactTranscriptionRequest{} = request) do
    with {:ok, adapter} <- adapter(),
         {:ok, %ArtifactTranscript{segments: segments} = transcript} <-
           adapter.transcribe(request),
         true <- is_list(segments) and length(segments) in 1..10_000,
         true <- Enum.all?(segments, &valid_segment?/1),
         true <- Enum.map(segments, & &1.sequence) == Enum.to_list(0..(length(segments) - 1)),
         true <- Enum.reduce(segments, 0, &(byte_size(&1.text) + &2)) <= 1_048_576 do
      {:ok, transcript}
    else
      {:error, _} = error -> error
      _ -> {:error, :artifact_transcription_contract_invalid}
    end
  end

  defp valid_segment?(%ArtifactTranscriptSegment{
         sequence: sequence,
         start_ms: start_ms,
         end_ms: end_ms,
         text: text
       }) do
    is_integer(sequence) and sequence >= 0 and is_integer(start_ms) and start_ms >= 0 and
      is_integer(end_ms) and end_ms >= start_ms and end_ms <= 28_800_000 and
      is_binary(text) and String.valid?(text) and byte_size(text) in 1..8_000
  end

  defp valid_segment?(_), do: false

  defp adapter do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :artifact_transcription_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <-
           function_exported?(adapter, :configured?, 0) and
             function_exported?(adapter, :transcribe, 1) do
      {:ok, adapter}
    else
      _ -> {:error, :transcription_unavailable}
    end
  end
end
