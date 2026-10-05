defmodule CommsCore.Accounts.ContentWriteGrant do
  @moduledoc false

  import Ecto.Query
  alias CommsCore.Accounts.{AccessControl, AccessGrant, Device, Session, User}
  alias CommsCore.{Administration, AdmissionQuotas, Repo}

  @lock_budget_ms 15_000

  @spec lock(map()) ::
          {:ok, AccessGrant.t()} | {:error, :forbidden | :transaction_required}
  def lock(subject),
    do: __MODULE__.lock(subject, System.monotonic_time(:millisecond) + @lock_budget_ms)

  @spec lock(map(), integer()) ::
          {:ok, AccessGrant.t()} | {:error, :forbidden | :transaction_required}
  def lock(subject, deadline) when is_map(subject) and is_integer(deadline) do
    if Repo.in_transaction?() do
      with {:ok, tenant_id} <- Ecto.UUID.cast(value(subject, :tenant_id)),
           {:ok, user_id} <- Ecto.UUID.cast(value(subject, :user_id)),
           {:ok, device_id} <- Ecto.UUID.cast(value(subject, :device_id)),
           {:ok, session_id} <- Ecto.UUID.cast(value(subject, :session_id)),
           :ok <- budgeted(deadline, fn -> AdmissionQuotas.lock_tenant(tenant_id) end),
           {:ok, _policy} <-
             budgeted(deadline, fn -> Administration.lock_call_policy(tenant_id) end),
           %User{} <-
             budgeted(deadline, fn ->
               timestamp = now()

               Repo.one(
                 from(user in User,
                   where:
                     user.id == ^user_id and user.tenant_id == ^tenant_id and
                       user.status == :active and
                       (user.account_type == :human or
                          (user.account_type == :guest and user.guest_expires_at > ^timestamp)),
                   # Fence current identity before caller resources without
                   # blocking unrelated User FK KEY SHARE references.
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
               timestamp = now()

               Repo.one(
                 from(session in Session,
                   where:
                     session.id == ^session_id and session.tenant_id == ^tenant_id and
                       session.user_id == ^user_id and session.device_id == ^device_id and
                       is_nil(session.revoked_at) and session.expires_at > ^timestamp and
                       session.absolute_expires_at > ^timestamp,
                   lock: "FOR SHARE"
                 )
               )
             end),
           {:ok, %AccessGrant{} = grant} <-
             budgeted(deadline, fn -> AccessControl.access_grant(subject) end) do
        {:ok, grant}
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock(_subject, _deadline), do: {:error, :forbidden}

  defp budgeted(deadline, operation) do
    budget!(deadline)
    result = operation.()
    budget!(deadline)
    result
  end

  defp budget!(deadline) do
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

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
