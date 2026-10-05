defmodule CommsCore.AudioCalls.ArtifactSummaryRequest do
  @moduledoc "Calls-owned disclosed-consent request over an immutable transcript digest."
  @enforce_keys [:artifact_id, :source_artifact_id, :source_sha256, :text, :deadline]
  defstruct [:artifact_id, :source_artifact_id, :source_sha256, :text, :deadline]

  @type t :: %__MODULE__{
          artifact_id: String.t(),
          source_artifact_id: String.t(),
          source_sha256: String.t(),
          text: String.t(),
          deadline: integer()
        }
end
