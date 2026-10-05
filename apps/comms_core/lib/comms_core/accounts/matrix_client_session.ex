defmodule CommsCore.Accounts.MatrixClientSession do
  @moduledoc false
  use CommsCore.Schema

  schema "matrix_client_sessions" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:device_id, Ecto.UUID)
    field(:session_id, Ecto.UUID)
    field(:matrix_identity_id, Ecto.UUID)
    field(:matrix_device_id, :string)
    field(:credential_secret, :map)

    field(:state, Ecto.Enum,
      values: [:pending, :ready, :cleanup_pending, :revoked],
      default: :pending
    )

    field(:claim_id, Ecto.UUID)
    field(:claim_expires_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:generation, :integer, default: 1)
    timestamps()
  end

  def retained_changeset(%__MODULE__{} = record, attrs), do: Ecto.Changeset.change(record, attrs)
end
