defmodule CommsCore.AudioCalls.ArtifactTranscriptionPort.Contract do
  @moduledoc "Calls-owned technical contract for explicit transcription."
  alias CommsCore.AudioCalls.{ArtifactTranscriptionRequest, ArtifactTranscript}
  @callback configured?() :: boolean()
  @callback transcribe(ArtifactTranscriptionRequest.t()) ::
              {:ok, ArtifactTranscript.t()} | {:error, atom()}
end
