defmodule CommsCore.Accounts.GuestIdentities.SessionReplay do
  @moduledoc false

  alias CommsCore.Accounts.{Device, Session, Sessions, User}

  alias CommsCore.Accounts.GuestIdentities.{
    ActiveSession,
    Persistence,
    Validation
  }

  alias CommsCore.{Audit, Repo}

  @spec resume_ephemeral(map(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :transaction_required
             | :forbidden
             | :session_expired
             | :tenant_unavailable
             | :invalid_ephemeral_guest_deadline
             | :invalid_guest_identity}
  def resume_ephemeral(command, effects) when is_map(command) and is_map(effects) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not Validation.ephemeral_room_authority?(command) ->
        {:error, :forbidden}

      true ->
        with {:ok, user_id} <- Validation.uuid(Validation.value(command, :user_id)),
             {:ok, session_id} <- Validation.uuid(Validation.value(command, :session_id)),
             {:ok, deadline} <-
               Validation.ephemeral_deadline(Validation.value(command, :expires_at)) do
          resume_in_transaction(
            user_id,
            session_id,
            Validation.value(command, :device) || %{},
            deadline,
            effects
          )
        else
          {:error, :invalid_uuid} -> {:error, :invalid_guest_identity}
          {:error, _reason} = error -> error
        end
    end
  end

  def resume_ephemeral(_command, _effects), do: {:error, :forbidden}

  defp resume_in_transaction(user_id, session_id, device_attrs, deadline, effects) do
    timestamp = Persistence.now()

    case ActiveSession.lock_active(session_id, timestamp, user_id) do
      nil ->
        {:error, :session_expired}

      %Session{} = active_session ->
        resume_active_session(active_session, device_attrs, deadline, timestamp, effects)
    end
  end

  defp resume_active_session(active_session, device_attrs, deadline, timestamp, effects) do
    if DateTime.compare(deadline, active_session.user.guest_expires_at) == :lt do
      {:error, :invalid_ephemeral_guest_deadline}
    else
      with {:ok, tenant} <- effects.active_tenant.(active_session.tenant_id) do
        user_changeset =
          User.guest_expiration_changeset(active_session.user, deadline)

        device_changeset =
          Device.changeset(
            active_session.device,
            resume_device_changes(device_attrs, timestamp)
          )

        with :ok <- valid_changeset(user_changeset),
             :ok <- valid_changeset(device_changeset) do
          user = update_or_rollback(user_changeset)

          active_session
          |> Session.changeset(%{revoked_at: timestamp})
          |> update_or_rollback()

          device = update_or_rollback(device_changeset)

          {replacement_session, refresh_token} =
            Sessions.create_guest_or_rollback(user, device, deadline, timestamp)

          Audit.record(%{
            tenant_id: user.tenant_id,
            actor_user_id: user.id,
            action: "guest_identity.resume_ephemeral",
            resource_type: "session",
            resource_id: replacement_session.id,
            metadata: %{
              previous_session_id: active_session.id,
              access_scope: "conversation_only"
            }
          })
          |> Persistence.audit_or_rollback()

          {:ok,
           CommsCore.Accounts.Projector.authentication(%{
             tenant: tenant,
             user: user,
             device: device,
             session: replacement_session,
             refresh_token: refresh_token,
             conversation: nil
           })}
        end
      end
    end
  end

  defp resume_device_changes(attrs, timestamp) when is_map(attrs) do
    %{last_seen_at: timestamp}
    |> maybe_put(:name, Validation.value(attrs, :name))
    |> maybe_put(:platform, Validation.value(attrs, :platform))
  end

  defp resume_device_changes(_attrs, timestamp), do: %{last_seen_at: timestamp}

  defp valid_changeset(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_changeset(%Ecto.Changeset{}), do: {:error, :invalid_guest_identity}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
