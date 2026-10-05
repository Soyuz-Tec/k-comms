defmodule CommsCore.AudioCalls.ArtifactSummarizationPort.Contract do
  @moduledoc "Exact independent summary effect; no owner schema or repository crosses this boundary."
  alias CommsCore.AudioCalls.{ArtifactSummaryRequest, ArtifactSummaryReceipt}
  @callback configured?() :: boolean()
  @callback summarize(ArtifactSummaryRequest.t()) ::
              {:ok, ArtifactSummaryReceipt.t()} | {:error, atom()}
end
