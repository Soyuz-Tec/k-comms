defmodule CommsCore.AudioCalls.ArtifactProviderEvent do
  @moduledoc "Authenticated, bounded provider callback projection owned by Calls."
  @enforce_keys [:event_id, :event_type, :provider_job_id, :provider_room, :state]
  defstruct [
    :event_id,
    :event_type,
    :provider_job_id,
    :provider_room,
    :state,
    :object_key,
    :byte_size,
    :occurred_at
  ]

  @type t :: %__MODULE__{}
end
