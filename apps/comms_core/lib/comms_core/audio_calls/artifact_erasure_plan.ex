defmodule CommsCore.AudioCalls.ArtifactErasurePlan do
  @moduledoc "Calls-owned aggregate receipt for durable governance artifact erasure."
  @enforce_keys [:pending_artifact_count]
  defstruct [:pending_artifact_count]
  @type t :: %__MODULE__{pending_artifact_count: non_neg_integer()}
end
