defmodule CommsCore.AudioCalls.ArtifactTranscriptionRequest do
  @moduledoc "Explicit Calls-owned transcription request for a verified recording version."
  @enforce_keys [:tenant_id, :artifact_id, :source_artifact_id, :object]
  defstruct [:tenant_id, :artifact_id, :source_artifact_id, :object]
  @type t :: %__MODULE__{}
end
