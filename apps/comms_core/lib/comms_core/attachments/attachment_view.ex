defmodule CommsCore.Attachments.AttachmentView do
  @moduledoc "Persistence-neutral attachment projection returned by the content boundary."

  @enforce_keys [:id, :tenant_id, :owner_user_id, :file_name, :content_type, :byte_size, :status]
  defstruct [
    :id,
    :tenant_id,
    :owner_user_id,
    :message_id,
    :object_key,
    :file_name,
    :content_type,
    :byte_size,
    :checksum_sha256,
    :object_version_id,
    :object_etag,
    :verified_checksum_sha256,
    :status,
    :scan_status,
    :scan_verdict,
    :scan_provider,
    :scan_attempts,
    :scan_error_code,
    :scanned_at,
    :quarantined_at,
    :scan_generation,
    :scan_claim_token,
    :scan_claimed_at,
    :uploaded_at,
    :inserted_at,
    :updated_at,
    scan_attempt_records: []
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          owner_user_id: Ecto.UUID.t(),
          message_id: Ecto.UUID.t() | nil,
          object_key: String.t(),
          file_name: String.t(),
          content_type: String.t(),
          byte_size: pos_integer(),
          checksum_sha256: String.t() | nil,
          object_version_id: String.t() | nil,
          object_etag: String.t() | nil,
          verified_checksum_sha256: String.t() | nil,
          status: atom(),
          scan_status: atom(),
          scan_verdict: String.t() | nil,
          scan_provider: String.t() | nil,
          scan_attempts: non_neg_integer(),
          scan_error_code: String.t() | nil,
          scanned_at: DateTime.t() | nil,
          quarantined_at: DateTime.t() | nil,
          scan_generation: non_neg_integer(),
          scan_claim_token: Ecto.UUID.t() | nil,
          scan_claimed_at: DateTime.t() | nil,
          uploaded_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t(),
          scan_attempt_records: [CommsCore.Attachments.ScanAttemptView.t()]
        }
end
