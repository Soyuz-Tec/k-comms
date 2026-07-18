defmodule CommsCore.Attachments.RestoredObjectIdentity do
  @moduledoc """
  Verified object identity returned to the attachment restore boundary.
  """

  @enforce_keys [
    :object_version_id,
    :object_etag,
    :verified_checksum_sha256,
    :etag_verification
  ]
  defstruct [
    :object_version_id,
    :object_etag,
    :verified_checksum_sha256,
    :etag_verification
  ]

  @type etag_verification :: :matched | :not_trustworthy

  @type t :: %__MODULE__{
          object_version_id: String.t(),
          object_etag: String.t(),
          verified_checksum_sha256: String.t(),
          etag_verification: etag_verification()
        }
end
