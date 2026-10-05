defmodule CommsIntegrations.MeetingArtifacts.ExtractiveSummary do
  @moduledoc "Bounded local summary: verbatim source quotes, never generated facts or provider receipts."
  @behaviour CommsCore.AudioCalls.ArtifactSummarizationPort.Contract
  alias CommsCore.AudioCalls.{ArtifactSummaryRequest, ArtifactSummaryReceipt}
  @model "extractive-quotes-v1"

  def configured?() do
    options = Application.get_env(:comms_integrations, :artifact_summarization, [])

    Keyword.keyword?(options) and Keyword.get(options, :enabled, false) == true and
      Keyword.get(options, :qualified, false) == true
  end

  def summarize(%ArtifactSummaryRequest{text: text, source_sha256: digest, deadline: deadline}) do
    with true <- configured?(),
         true <- System.monotonic_time(:millisecond) < deadline,
         true <- is_binary(text) and String.valid?(text) and byte_size(text) in 1..131_072,
         true <- is_binary(digest) and Regex.match?(~r/^[a-f0-9]{64}$/, digest),
         quotes when quotes != [] <- select_quotes(text),
         result <- Enum.map_join(quotes, "\n\n", & &1),
         true <- byte_size(result) in 1..16_384,
         true <- System.monotonic_time(:millisecond) < deadline do
      {:ok,
       %ArtifactSummaryReceipt{
         provider_id: "local-extractive:" <> digest,
         model: @model,
         source_sha256: digest,
         text: result
       }}
    else
      _ -> {:error, :summary_unavailable}
    end
  end

  def summarize(_), do: {:error, :invalid_artifact_summary_request}

  # Prefer decisions/actions/questions but retain source order. Every output
  # quote is an unchanged complete source line; do not infer speakers or facts.
  def select_quotes(text) when is_binary(text) and byte_size(text) <= 131_072 do
    text
    |> String.split("\n", trim: true)
    |> Enum.with_index()
    |> Enum.filter(fn {line, _} -> byte_size(line) in 1..2_000 end)
    |> Enum.map(fn {line, index} ->
      score =
        if Regex.match?(
             ~r/\b(decid(?:e|ed)|agree(?:d)?|action|next|will|must|deadline|follow up)\b|\?/iu,
             line
           ), do: 1, else: 0

      {line, index, score}
    end)
    |> Enum.sort_by(fn {_, index, score} -> {-score, index} end)
    |> Enum.take(6)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  def select_quotes(_), do: []
end
