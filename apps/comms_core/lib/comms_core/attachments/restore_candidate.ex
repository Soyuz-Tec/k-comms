defmodule CommsCore.Attachments.RestoreCandidate do
  @moduledoc """
  Persistence-neutral attachment identity supplied to restore verifiers.

  The contract contains only the object metadata required to verify restored
  bytes. Attachment lifecycle and persistence state remain internal to
  `CommsCore.Attachments`.
  """

  @enforce_keys [
    :id,
    :tenant_id,
    :object_key,
    :byte_size,
    :checksum_sha256,
    :object_etag,
    :verified_checksum_sha256
  ]
  defstruct [
    :id,
    :tenant_id,
    :object_key,
    :byte_size,
    :checksum_sha256,
    :object_etag,
    :verified_checksum_sha256
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          object_key: String.t(),
          byte_size: pos_integer(),
          checksum_sha256: String.t() | nil,
          object_etag: String.t() | nil,
          verified_checksum_sha256: String.t() | nil
        }
end
