defmodule CommsIntegrations.MeetingArtifacts.TranscriptResponse do
  @moduledoc false

  alias CommsCore.AudioCalls.{ArtifactTranscript, ArtifactTranscriptSegment}

  @maximum_segments 10_000
  @maximum_timestamp_ms 28_800_000

  def normalize(%{"segments" => segments} = response)
      when is_list(segments) and length(segments) in 1..@maximum_segments do
    with {:ok, language} <- language(response["language"]),
         {:ok, normalized} <- normalize_segments(segments) do
      {:ok, %ArtifactTranscript{language: language, segments: normalized}}
    end
  end

  def normalize(_), do: {:error, :invalid_artifact_transcript}

  defp normalize_segments(segments) do
    segments
    |> Enum.with_index(0)
    |> Enum.reduce_while({:ok, [], 0}, fn {segment, sequence}, {:ok, acc, previous_start} ->
      with true <- is_map(segment),
           {:ok, start_ms} <- timestamp(segment["start"]),
           {:ok, end_ms} <- timestamp(segment["end"]),
           true <- start_ms >= previous_start and end_ms >= start_ms,
           text when is_binary(text) <- segment["text"],
           text <- String.trim(text),
           true <- byte_size(text) in 1..8_000 and String.valid?(text),
           true <- not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, text) do
        normalized = %ArtifactTranscriptSegment{
          sequence: sequence,
          start_ms: start_ms,
          end_ms: end_ms,
          text: text
        }

        {:cont, {:ok, [normalized | acc], start_ms}}
      else
        _ -> {:halt, {:error, :invalid_artifact_transcript}}
      end
    end)
    |> case do
      {:ok, segments, _} -> {:ok, Enum.reverse(segments)}
      error -> error
    end
  end

  defp timestamp(seconds) when is_number(seconds) and seconds >= 0 do
    milliseconds = round(seconds * 1_000)

    if milliseconds <= @maximum_timestamp_ms,
      do: {:ok, milliseconds},
      else: {:error, :invalid_artifact_transcript}
  end

  defp timestamp(_), do: {:error, :invalid_artifact_transcript}
  defp language(nil), do: {:ok, nil}

  defp language(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z][A-Za-z -]{0,79}$/, value),
      do: {:ok, value},
      else: {:error, :invalid_artifact_transcript}
  end

  defp language(_), do: {:error, :invalid_artifact_transcript}
end
