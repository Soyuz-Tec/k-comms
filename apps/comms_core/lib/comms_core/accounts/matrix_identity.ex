defmodule CommsCore.Accounts.MatrixIdentity do
  @moduledoc false
  use CommsCore.Schema

  schema "matrix_identities" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:issuer, :string)
    field(:matrix_user_id, :string)
    field(:auth_secret, :map)
    field(:key_cleanup_state, :string, default: "unconfirmed")
    field(:erasure_requested_at, :utc_datetime_usec)

    field(:state, Ecto.Enum,
      values: [:pending, :ready, :cleanup_pending, :erased],
      default: :pending
    )

    field(:claim_id, Ecto.UUID)
    field(:claim_expires_at, :utc_datetime_usec)
    field(:generation, :integer, default: 1)
    timestamps()
  end

  def retained_changeset(%__MODULE__{} = record, attrs), do: Ecto.Changeset.change(record, attrs)
end
