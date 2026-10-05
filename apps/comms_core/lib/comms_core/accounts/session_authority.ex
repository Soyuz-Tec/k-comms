defmodule CommsCore.Accounts.SessionAuthority do
  @moduledoc false

  import Ecto.Query, except: [lock: 2]
  alias CommsCore.Accounts.{AccessControl, Device, Session, User}
  alias CommsCore.{Administration, Repo}

  # Hold every current human authority row through a sensitive identity effect.
  # User-before-device-before-session matches factor/reset and device revocation
  # workflows; factor locks must be acquired only after these locks.
  def lock(subject), do: lock(subject, System.monotonic_time(:millisecond) + 15_000)

  def lock(subject, deadline) when is_map(subject) and is_integer(deadline) do
    if Repo.in_transaction?() do
      with {:ok, tenant_id} <- Ecto.UUID.cast(value(subject, :tenant_id)),
           {:ok, user_id} <- Ecto.UUID.cast(value(subject, :user_id)),
           {:ok, device_id} <- Ecto.UUID.cast(value(subject, :device_id)),
           {:ok, session_id} <- Ecto.UUID.cast(value(subject, :session_id)),
           # This existing tenant-owned projection holds the active Tenant row.
           # Identity authority does not depend on its voice/video policy flags.
           {:ok, _policy} <-
             budgeted(deadline, fn -> Administration.lock_call_policy(tenant_id) end),
           %User{} <-
             budgeted(deadline, fn ->
               Repo.one(
                 from(user in User,
                   where:
                     user.id == ^user_id and user.tenant_id == ^tenant_id and
                       user.status == :active and user.account_type == :human,
                   # Identity fields remain fenced, while session-owning reads
                   # may finish their User FK references before we acquire the
                   # retained Session. Authority never changes User key columns.
                   lock: "FOR NO KEY UPDATE"
                 )
               )
             end),
           %Device{} <-
             budgeted(deadline, fn ->
               Repo.one(
                 from(device in Device,
                   where:
                     device.id == ^device_id and device.tenant_id == ^tenant_id and
                       device.user_id == ^user_id and is_nil(device.revoked_at),
                   lock: "FOR SHARE"
                 )
               )
             end),
           %Session{} <-
             budgeted(deadline, fn ->
               Repo.one(
                 from(session in Session,
                   where:
                     session.id == ^session_id and session.tenant_id == ^tenant_id and
                       session.user_id == ^user_id and session.device_id == ^device_id and
                       is_nil(session.revoked_at) and session.expires_at > ^now() and
                       session.absolute_expires_at > ^now(),
                   lock: "FOR UPDATE"
                 )
               )
             end),
           {:ok, grant} <- budgeted(deadline, fn -> AccessControl.access_grant(subject) end) do
        {:ok, grant}
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock(_, _), do: {:error, :forbidden}

  def lock_active_tenant(tenant_id, deadline) do
    if Repo.in_transaction?() do
      with {:ok, _policy} <-
             budgeted(deadline, fn -> Administration.lock_call_policy(tenant_id) end),
           {:ok, tenant} <- budgeted(deadline, fn -> Administration.active_tenant(tenant_id) end) do
        {:ok, tenant}
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  # One absolute budget covers sequential lock waits, rather than granting the
  # original timeout again to every query. Settings are local to the owning tx.
  def ensure_budget(deadline) when is_integer(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)
    :ok
  end

  defp budgeted(deadline, operation) do
    ensure_budget(deadline)
    result = operation.()
    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)
    result
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
