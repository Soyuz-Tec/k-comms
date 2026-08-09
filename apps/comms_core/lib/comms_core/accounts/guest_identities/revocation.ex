defmodule CommsCore.Accounts.GuestIdentities.Revocation do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{CallLifecycleCommand, Session, User}
  alias CommsCore.Accounts.GuestIdentities.{Persistence, Validation}
  alias CommsCore.{Audit, Repo}

  @spec revoke_session(Ecto.UUID.t(), String.t(), map()) ::
          :ok | {:error, :not_found | :invalid_reason | term()}
  def revoke_session(session_id, reason, effects)
      when is_binary(session_id) and is_binary(reason) and is_map(effects) do
    reason = String.trim(reason)

    cond do
      reason == "" or String.length(reason) > 160 ->
        {:error, :invalid_reason}

      match?({:error, :invalid_uuid}, Validation.uuid(session_id)) ->
        {:error, :not_found}

      true ->
        Persistence.run_transaction_aware(fn ->
          revoke_in_transaction(session_id, reason, effects)
        end)
    end
  end

  def revoke_session(_session_id, _reason, _effects), do: {:error, :invalid_reason}

  defp revoke_in_transaction(session_id, reason, effects) do
    session =
      Repo.one(
        from(session in Session,
          join: user in User,
          on: user.id == session.user_id and user.tenant_id == session.tenant_id,
          where: session.id == ^session_id and user.account_type == :guest,
          preload: [user: user],
          lock: "FOR UPDATE"
        )
      )

    case session do
      nil ->
        {:error, :not_found}

      %Session{revoked_at: %DateTime{}} = revoked_session ->
        expire_user(revoked_session.user, Persistence.now())
        :ok

      %Session{} = active_session ->
        revoke_active_session(active_session, reason, effects)
    end
  end

  defp revoke_active_session(active_session, reason, effects) do
    revoked_at = Persistence.now()
    expire_user(active_session.user, revoked_at)

    active_session
    |> Session.changeset(%{revoked_at: revoked_at})
    |> update_or_rollback()

    CallLifecycleCommand.sessions_revoked(
      active_session.tenant_id,
      [active_session.id],
      reason
    )
    |> effects.revoke_identity_access.()

    Audit.record(%{
      tenant_id: active_session.tenant_id,
      actor_user_id: nil,
      action: "guest_session.revoke",
      resource_type: "session",
      resource_id: active_session.id,
      metadata: %{reason: reason}
    })
    |> Persistence.audit_or_rollback()

    :ok
  end

  defp expire_user(%User{account_type: :guest} = user, timestamp) do
    if DateTime.compare(user.guest_expires_at, timestamp) == :gt do
      user
      |> User.guest_expiration_changeset(timestamp)
      |> update_or_rollback()
    else
      user
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
