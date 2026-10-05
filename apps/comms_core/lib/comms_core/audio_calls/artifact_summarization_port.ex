defmodule CommsCore.AudioCalls.ArtifactSummarizationPort do
  @moduledoc "Optional Calls-owned bounded summary provider; disabled unless independently qualified."
  alias CommsCore.AudioCalls.{ArtifactSummaryRequest, ArtifactSummaryReceipt}
  @spec configured?() :: boolean()
  def configured?() do
    with {:ok, adapter} <- adapter(), do: adapter.configured?(), else: (_ -> false)
  end

  @spec summarize(ArtifactSummaryRequest.t()) ::
          {:ok, ArtifactSummaryReceipt.t()} | {:error, atom()}
  def summarize(%ArtifactSummaryRequest{} = request) do
    with {:ok, adapter} <- adapter(),
         {:ok, %ArtifactSummaryReceipt{} = receipt} <- adapter.summarize(request),
         true <- receipt.source_sha256 == request.source_sha256,
         true <- receipt.model == "extractive-quotes-v1",
         true <- source_quotes?(receipt.text, request.text),
         true <- valid_text?(receipt.text),
         true <- is_binary(receipt.provider_id) and byte_size(receipt.provider_id) in 1..200 do
      {:ok, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_artifact_summary}
    end
  end

  def summarize(_), do: {:error, :invalid_artifact_summary_request}

  defp source_quotes?(text, source) when is_binary(text) and is_binary(source) do
    quotes = String.split(text, "\n\n")
    original = source |> String.split("\n", trim: true) |> MapSet.new()
    length(quotes) in 1..6 and Enum.all?(quotes, &MapSet.member?(original, &1))
  end

  defp source_quotes?(_, _), do: false

  defp valid_text?(text),
    do:
      is_binary(text) and String.valid?(text) and byte_size(text) in 1..16_384 and
        not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, text)

  defp adapter do
    with {:ok, module} <- Application.fetch_env(:comms_core, :artifact_summarization_adapter),
         true <- is_atom(module) and Code.ensure_loaded?(module),
         true <-
           function_exported?(module, :configured?, 0) and
             function_exported?(module, :summarize, 1),
         do: {:ok, module},
         else: (_ -> {:error, :summarization_unavailable})
  end
end
