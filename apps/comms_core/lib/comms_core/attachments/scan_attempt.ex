defmodule CommsCore.Attachments.ScanAttempt do
  use CommsCore.Schema

  schema "attachment_scan_attempts" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    field(:attachment_id, :binary_id)
    field(:attempt_number, :integer)
    field(:provider, :string)
    field(:status, Ecto.Enum, values: [:clean, :blocked, :retryable, :failed])
    field(:verdict, :string)
    field(:error_code, :string)
    field(:provider_reference, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    timestamps(updated_at: false)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :tenant_id,
      :attachment_id,
      :attempt_number,
      :provider,
      :status,
      :verdict,
      :error_code,
      :provider_reference,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :tenant_id,
      :attachment_id,
      :attempt_number,
      :provider,
      :status,
      :started_at,
      :completed_at
    ])
    |> validate_number(:attempt_number, greater_than: 0)
    |> unique_constraint([:attachment_id, :attempt_number])
    |> foreign_key_constraint(:attachment_id,
      name: :attachment_scan_attempts_tenant_attachment_id_fk
    )
  end
end
