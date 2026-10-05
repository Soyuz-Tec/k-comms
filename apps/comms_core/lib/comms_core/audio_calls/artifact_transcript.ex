defmodule CommsCore.AudioCalls.ArtifactTranscript do
  @moduledoc "Bounded, provider-normalized transcript; text is Restricted meeting content."
  @enforce_keys [:segments]
  defstruct [:language, :segments]
  @type t :: %__MODULE__{}
end
