defmodule CommsCore.Accounts.NativePushAuthority do
  @moduledoc "Retained current human/device/session authority for native registration and wake effects."
  import Ecto.Query
  alias CommsCore.Accounts.{AccessControl, AccessGrant, Device, Session, SessionAuthority, User}
  alias CommsCore.Repo

  @enforce_keys [:tenant_id, :user_id, :device_id, :session_id, :user_version, :expires_at]
  defstruct [:tenant_id, :user_id, :device_id, :session_id, :user_version, :expires_at]
  @type t :: %__MODULE__{tenant_id: binary(), user_id: binary(), device_id: binary(),
                         session_id: binary(), user_version: pos_integer(), expires_at: DateTime.t()}

  # Caller retains the canonical governance tenant fence and registration quota
  # lock before this command. These locks match identity lifecycle writer order.
  def lock(subject, deadline) when is_map(subject) and is_integer(deadline) do
    if Repo.in_transaction?() do
      with {:ok, tenant} <- Ecto.UUID.cast(value(subject, :tenant_id)),
           {:ok, user} <- Ecto.UUID.cast(value(subject, :user_id)),
           {:ok, device} <- Ecto.UUID.cast(value(subject, :device_id)),
           {:ok, session} <- Ecto.UUID.cast(value(subject, :session_id)),
           {:ok, _} <- SessionAuthority.lock_active_tenant(tenant, deadline),
           %User{} = owner <- budget(deadline, fn ->
             Repo.one(from(u in User, where: u.id == ^user and u.tenant_id == ^tenant and
               u.status == :active and u.account_type == :human, lock: "FOR NO KEY UPDATE"))
           end),
           %Device{} <- budget(deadline, fn ->
             Repo.one(from(d in Device, where: d.id == ^device and d.tenant_id == ^tenant and
               d.user_id == ^user and is_nil(d.revoked_at), lock: "FOR SHARE"))
           end),
           %Session{} <- budget(deadline, fn ->
             Repo.one(from(s in Session, where: s.id == ^session and s.tenant_id == ^tenant and
               s.user_id == ^user and s.device_id == ^device and is_nil(s.revoked_at) and
               s.expires_at > ^DateTime.utc_now() and s.absolute_expires_at > ^DateTime.utc_now(),
               lock: "FOR SHARE"))
           end),
           {:ok, %AccessGrant{account_type: :human} = grant} <- budget(deadline, fn -> AccessControl.access_grant(subject) end) do
        {:ok, %__MODULE__{tenant_id: tenant, user_id: user, device_id: device, session_id: session,
                          user_version: owner.lock_version, expires_at: grant.effective_expires_at}}
      else
        _ -> {:error, :native_push_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end
  def lock(_, _), do: {:error, :native_push_unavailable}
  defp budget(deadline, operation) do
    SessionAuthority.ensure_budget(deadline)
    result = operation.()
    SessionAuthority.ensure_budget(deadline)
    result
  end
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
