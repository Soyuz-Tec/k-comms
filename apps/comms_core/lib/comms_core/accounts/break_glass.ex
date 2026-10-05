defmodule CommsCore.Accounts.BreakGlass do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Accounts.{Mfa, Projector, Session, SessionAuthority, User}
  alias CommsCore.Accounts.Sessions.{Authentication, Persistence, RefreshTokens}
  alias CommsCore.Repo

  # Console-only operation. It has no HTTP endpoint and does not reset an identity,
  # elevate a role, or remove an enrolled factor.
  def create(attrs) do
    secret = Application.get_env(:comms_core, :identity_break_glass_secret)
    token = Persistence.value(attrs, :credential_token)
    actor = Persistence.value(attrs, :actor)
    reason = Persistence.value(attrs, :reason)

    with true <- is_binary(secret) and byte_size(secret) >= 32,
         true <-
           is_binary(token) and byte_size(token) == byte_size(secret) and
             :crypto.hash_equals(secret, token),
         true <- is_binary(actor) and byte_size(actor) in 3..120,
         true <- is_binary(reason) and byte_size(reason) in 3..1000,
         {:ok, %{user: user, tenant: tenant}} <-
           Authentication.verify_identity(
             Persistence.value(attrs, :tenant_slug),
             Persistence.value(attrs, :email),
             Persistence.value(attrs, :password)
           ),
         true <- user.role == :owner and user.access_scope == :workspace do
      verified_password_hash = user.password_hash
      authority_deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          tenant =
            case SessionAuthority.lock_active_tenant(tenant.id, authority_deadline) do
              {:ok, current} -> current
              {:error, _} -> Repo.rollback(:invalid_break_glass_credentials)
            end

          SessionAuthority.ensure_budget(authority_deadline)

          user =
            Repo.one(
              from(u in User,
                where:
                  u.id == ^user.id and u.tenant_id == ^user.tenant_id and u.role == :owner and
                    u.status == :active and u.account_type == :human and
                    u.access_scope == :workspace,
                lock: "FOR UPDATE"
              )
            )

          with %User{} <- user,
               true <- user.password_hash == verified_password_hash,
               :ok <- factor(user, Persistence.value(attrs, :mfa_code)) do
            SessionAuthority.ensure_budget(authority_deadline)

            {:ok, device} =
              Persistence.upsert_device(user, %{
                name: "Emergency owner recovery",
                platform: "console_recovery"
              })

            SessionAuthority.ensure_budget(authority_deadline)

            id = Ecto.UUID.generate()
            {refresh_token, hash} = RefreshTokens.new_refresh_token(id)
            now = Persistence.now()
            deadline = DateTime.add(now, 900)

            session =
              %Session{id: id, authentication_method: "break_glass", mfa_verified_at: now}
              |> Session.changeset(%{
                tenant_id: user.tenant_id,
                user_id: user.id,
                device_id: device.id,
                refresh_token_hash: hash,
                expires_at: deadline,
                absolute_expires_at: deadline,
                last_used_at: now
              })
              |> Repo.insert!()

            Persistence.insert_audit!(
              %{tenant_id: user.tenant_id, user_id: user.id},
              "identity.break_glass_used",
              "session",
              id,
              %{operator: actor, reason: reason, expires_at: deadline, alert_required: true}
            )

            {:ok,
             Projector.authentication(%{
               user: user,
               tenant: tenant,
               device: device,
               session: session,
               refresh_token: refresh_token
             })}
          else
            _ -> {:error, :invalid_break_glass_credentials}
          end
        end,
        timeout: 20_000
      )
      |> case do
        {:ok, result} -> result
        {:error, _} -> {:error, :invalid_break_glass_credentials}
      end
    else
      _ -> {:error, :invalid_break_glass_credentials}
    end
  end

  defp factor(user, code) do
    if Mfa.enabled?(user.id, user.tenant_id),
      do: Mfa.verify(user.id, user.tenant_id, code),
      else: :ok
  end
end
