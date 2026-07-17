defmodule CommsCore.Attachments.Attachment do
  use CommsCore.Schema

  schema "attachments" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:owner_user, CommsCore.Accounts.User)
    field(:message_id, :binary_id)
    field(:object_key, :string)
    field(:file_name, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:checksum_sha256, :string)
    field(:object_version_id, :string)
    field(:object_etag, :string)
    field(:verified_checksum_sha256, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :uploaded, :ready, :quarantined, :scan_failed, :deleted],
      default: :pending
    )

    field(:scan_status, Ecto.Enum,
      values: [:pending, :scanning, :clean, :blocked, :failed],
      default: :pending
    )

    field(:scan_verdict, :string)
    field(:scan_provider, :string)
    field(:scan_attempts, :integer, default: 0)
    field(:scan_error_code, :string)
    field(:scanned_at, :utc_datetime_usec)
    field(:quarantined_at, :utc_datetime_usec)
    field(:scan_generation, :integer, default: 0)
    field(:scan_claim_token, Ecto.UUID)
    field(:scan_claimed_at, :utc_datetime_usec)
    field(:uploaded_at, :utc_datetime_usec)
    has_many(:scan_attempt_records, CommsCore.Attachments.ScanAttempt)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
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
      :uploaded_at
    ])
    |> validate_required([
      :tenant_id,
      :owner_user_id,
      :object_key,
      :file_name,
      :content_type,
      :byte_size,
      :status,
      :scan_status,
      :scan_attempts
    ])
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: 1_073_741_824)
    |> validate_length(:file_name, min: 1, max: 255)
    |> validate_length(:content_type, min: 1, max: 120)
    |> validate_number(:scan_attempts, greater_than_or_equal_to: 0)
    |> validate_number(:scan_generation, greater_than_or_equal_to: 0)
    |> validate_format(:checksum_sha256, ~r/^[a-f0-9]{64}$/)
    |> validate_format(:verified_checksum_sha256, ~r/^[a-f0-9]{64}$/)
    |> unique_constraint(:object_key)
    |> check_constraint(:status, name: :attachments_ready_requires_current_clean_version)
    |> check_constraint(:scan_claim_token, name: :attachments_scan_claim_consistent)
  end
end
