defmodule CommsCore.AudioCalls.ArtifactTranscriptSegment do
  @moduledoc "Persistence-neutral transcript segment."
  @enforce_keys [:sequence, :start_ms, :end_ms, :text]
  defstruct [:sequence, :start_ms, :end_ms, :text]
  @type t :: %__MODULE__{}
end
