defmodule CommsCore.AudioCalls.ArtifactProviderReceipt do
  @moduledoc "Provider job identity; capture acceptance is distinct from qualification."
  @enforce_keys [:provider_job_id, :provider_room, :object_key, :state]
  defstruct [:provider_job_id, :provider_room, :object_key, :state, :byte_size]
  @type t :: %__MODULE__{}
end
