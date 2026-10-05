defmodule CommsCore.AudioCalls.ArtifactTranscript do
  @moduledoc "Bounded, provider-normalized transcript; text is Restricted meeting content."
  @enforce_keys [:segments]
  defstruct [:language, :segments, :provider_id, :model_sha256, :source_sha256]
  @type t :: %__MODULE__{}
end
