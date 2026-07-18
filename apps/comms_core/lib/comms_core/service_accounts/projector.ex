defmodule CommsCore.ServiceAccounts.Projector do
  @moduledoc false
  alias CommsCore.ServiceAccounts.{ServiceAccount, ServiceAccountView}

  def service_account(%ServiceAccount{} = account) do
    struct!(ServiceAccountView, %{
      id: account.id,
      tenant_id: account.tenant_id,
      user_id: account.user_id,
      device_id: account.device_id,
      name: account.name,
      credential_prefix: account.credential_prefix,
      secret_hint: account.secret_hint,
      scopes: account.scopes,
      status: account.status,
      expires_at: account.expires_at,
      last_used_at: account.last_used_at,
      last_rotated_at: account.last_rotated_at,
      revoked_at: account.revoked_at,
      version: account.lock_version,
      inserted_at: account.inserted_at,
      updated_at: account.updated_at
    })
  end
end
