defmodule CommsCore.Accounts.MfaFactor do
  @moduledoc false
  use CommsCore.Schema

  schema "identity_mfa_factors" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:ciphertext, :binary, redact: true)
    field(:nonce, :binary, redact: true)
    field(:tag, :binary, redact: true)
    field(:key_id, :string)
    field(:enabled_at, :utc_datetime_usec)
    field(:last_used_step, :integer, default: -1)
    field(:recovery_hashes, {:array, :binary}, default: [], redact: true)
    field(:failed_attempts, :integer, default: 0)
    field(:locked_until, :utc_datetime_usec)
    timestamps()
  end
end
