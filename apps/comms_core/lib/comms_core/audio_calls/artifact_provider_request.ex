defmodule CommsCore.AudioCalls.ArtifactProviderRequest do
  @moduledoc "Calls-owned, server-derived command for bounded meeting capture."
  @enforce_keys [
    :tenant_id,
    :conversation_id,
    :call_id,
    :artifact_id,
    :provider_room,
    :object_key,
    :content_type
  ]
  defstruct [
    :tenant_id,
    :conversation_id,
    :call_id,
    :artifact_id,
    :provider_room,
    :provider_job_id,
    :object_key,
    :content_type,
    :operation_key
  ]

  @type t :: %__MODULE__{}
end
