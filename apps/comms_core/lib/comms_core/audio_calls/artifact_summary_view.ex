defmodule CommsCore.AudioCalls.ArtifactSummaryView do
  @moduledoc "Restricted selected quotes with immutable source and output proofs."
  @enforce_keys [:source_artifact_id, :source_sha256, :summary_sha256, :text, :policy_version]
  defstruct [
    :source_artifact_id,
    :source_sha256,
    :summary_sha256,
    :text,
    :policy_version,
    method: "extractive_quotes"
  ]

  @type t :: %__MODULE__{}
end
