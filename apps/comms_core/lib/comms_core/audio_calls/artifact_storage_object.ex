defmodule CommsCore.AudioCalls.ArtifactStorageObject do
  @moduledoc "Calls-owned version-pinned object identity for approved storage."
  @enforce_keys [:tenant_id, :object_key, :content_type]
  defstruct [
    :tenant_id,
    :object_key,
    :content_type,
    :object_version_id,
    :checksum_sha256,
    :verified_checksum_sha256,
    :object_etag,
    :byte_size
  ]

  @type t :: %__MODULE__{}
end
