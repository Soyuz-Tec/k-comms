defmodule CommsCore.ServiceAccounts.ServiceAccountView do
  @moduledoc "Stable service-account projection without credential persistence fields."
  defstruct [
    :id,
    :tenant_id,
    :user_id,
    :device_id,
    :name,
    :credential_prefix,
    :secret_hint,
    :scopes,
    :status,
    :expires_at,
    :last_used_at,
    :last_rotated_at,
    :revoked_at,
    :version,
    :inserted_at,
    :updated_at
  ]
end
