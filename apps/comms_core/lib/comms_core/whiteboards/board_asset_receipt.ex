defmodule CommsCore.Whiteboards.BoardAssetReceipt do
  @moduledoc "Version-pinned raster asset receipt; storage identity is server-side only."
  @enforce_keys [
    :attachment_id,
    :source_message_id,
    :content_type,
    :byte_size,
    :object_key,
    :object_version_id,
    :object_etag,
    :checksum_sha256,
    :verified_checksum_sha256
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          attachment_id: binary(),
          source_message_id: binary(),
          content_type: binary(),
          byte_size: pos_integer(),
          object_key: binary(),
          object_version_id: binary(),
          object_etag: binary(),
          checksum_sha256: binary(),
          verified_checksum_sha256: binary()
        }
end
