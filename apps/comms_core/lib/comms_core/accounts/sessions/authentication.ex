defmodule CommsCore.Accounts.Sessions.Authentication do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.Sessions.{Persistence, RefreshTokens}
  alias CommsCore.Accounts.{SessionAuthority, User}
  alias CommsCore.{Administration, Repo}
  alias CommsCore.Security.Password

  @authentication_failure_floor_ms 500
  @authentication_failure_jitter_ms 50

  def authenticate(tenant_slug, email, password, device_attrs \\ %{}) do
    started_at = System.monotonic_time(:millisecond)
    result = authenticate_identity(tenant_slug, email, password, device_attrs)
    pad_authentication_failure(result, started_at)
    result
  end

  defp authenticate_identity(tenant_slug, email, password, device_attrs) do
    with {:ok, %{user: verified_user, tenant: tenant}} <-
           verify_identity(tenant_slug, email, password) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          tenant =
            case SessionAuthority.lock_active_tenant(tenant.id, deadline) do
              {:ok, current} -> current
              {:error, _} -> Repo.rollback(:invalid_credentials)
            end

          SessionAuthority.ensure_budget(deadline)

          user =
            Repo.one(
              from(user in User,
                where:
                  user.id == ^verified_user.id and user.tenant_id == ^verified_user.tenant_id and
                    user.status == :active and user.account_type == :human,
                lock: "FOR UPDATE"
              )
            ) || Repo.rollback(:invalid_credentials)

          if user.password_hash != verified_user.password_hash,
            do: Repo.rollback(:invalid_credentials)

          SessionAuthority.ensure_budget(deadline)

          if CommsCore.Accounts.MfaFactorState.enabled?(user.id, user.tenant_id),
            do: Repo.rollback(:mfa_required)

          with {:ok, device} <- Persistence.upsert_device(user, device_attrs),
               :ok <- SessionAuthority.ensure_budget(deadline),
               {:ok, session, refresh_token} <- RefreshTokens.create(user, device) do
            %{
              tenant: tenant,
              user: user,
              device: device,
              session: session,
              refresh_token: refresh_token
            }
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout: 20_000
      )
    end
  end

  def verify_identity(tenant_slug, email, password) do
    started_at = System.monotonic_time(:millisecond)
    normalized_email = email |> to_string() |> String.trim() |> String.downcase()

    tenant =
      case Administration.active_tenant_by_slug(tenant_slug) do
        {:ok, tenant} -> tenant
        _ -> nil
      end

    user =
      if tenant do
        Repo.one(
          from(u in User,
            where:
              u.tenant_id == ^tenant.id and u.status == :active and u.account_type == :human and
                fragment("lower(?)", u.email) == ^normalized_email
          )
        )
      end

    result =
      with %{} <- tenant,
           %User{} <- user,
           true <- Password.verify(password, user.password_hash),
           {:ok, user} <- maybe_upgrade_password_hash(user, password),
           {:ok, active_tenant} <- Administration.active_tenant(tenant.id) do
        {:ok, %{user: user, tenant: active_tenant}}
      else
        _ ->
          if is_nil(user), do: Password.verify(password, nil)
          {:error, :invalid_credentials}
      end

    pad_authentication_failure(result, started_at)
    result
  end

  defp pad_authentication_failure({:error, :invalid_credentials}, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    jitter_ms = :rand.uniform(@authentication_failure_jitter_ms + 1) - 1

    Process.sleep(max(@authentication_failure_floor_ms + jitter_ms - elapsed_ms, 0))
  end

  defp pad_authentication_failure(_result, _started_at), do: :ok

  defp maybe_upgrade_password_hash(%User{} = user, password) do
    if Password.needs_rehash?(user.password_hash) do
      upgraded_hash = Password.hash(password)

      query =
        from(existing in User,
          where:
            existing.id == ^user.id and existing.tenant_id == ^user.tenant_id and
              existing.password_hash == ^user.password_hash
        )

      case Repo.update_all(query,
             set: [password_hash: upgraded_hash, updated_at: Persistence.now()]
           ) do
        {1, _} -> {:ok, %{user | password_hash: upgraded_hash}}
        _ -> {:error, :invalid_credentials}
      end
    else
      {:ok, user}
    end
  end
end
