defmodule CommsCore.Accounts.GuestIdentities.Conversion do
  @moduledoc false

  alias CommsCore.Accounts.{
    CallLifecycleCommand,
    Device,
    Session,
    Sessions,
    User
  }

  alias CommsCore.Accounts.GuestIdentities.{Persistence, Validation}
  alias CommsCore.{Audit, Repo}
  alias CommsCore.Security.Password

  @spec convert(map(), map(), String.t(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :forbidden
             | :guest_account_conversion_email_mismatch
             | :session_expired
             | :tenant_unavailable
             | :weak_password
             | :invalid_guest_account}
  def convert(attrs, guest_subject, preauthorized_email, effects)
      when is_map(attrs) and is_map(guest_subject) and
             is_binary(preauthorized_email) and is_map(effects) do
    expected_email = Validation.normalize_email(preauthorized_email)

    if expected_email != "" and
         Validation.normalize_email(Validation.value(attrs, :email)) ==
           expected_email do
      fn ->
        convert_in_transaction(
          attrs,
          guest_subject,
          expected_email,
          effects
        )
      end
      |> Persistence.run_transaction_aware()
      |> normalize_account_result(effects)
    else
      {:error, :guest_account_conversion_email_mismatch}
    end
  end

  def convert(_attrs, _guest_subject, _preauthorized_email, _effects),
    do: {:error, :forbidden}

  @spec convert_ephemeral(map(), map(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :forbidden
             | :transaction_required
             | :session_expired
             | :tenant_unavailable
             | :weak_password
             | :invalid_guest_account}
  def convert_ephemeral(attrs, guest_subject, effects)
      when is_map(attrs) and is_map(guest_subject) and is_map(effects) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not Validation.ephemeral_room_authority?(guest_subject) ->
        {:error, :forbidden}

      true ->
        attrs
        |> convert_ephemeral_in_transaction(guest_subject, effects)
        |> normalize_account_result(effects)
    end
  end

  def convert_ephemeral(_attrs, _guest_subject, _effects),
    do: {:error, :forbidden}

  defp convert_in_transaction(
         attrs,
         guest_subject,
         preauthorized_email,
         effects
       ) do
    password = Validation.value(attrs, :password)
    email = Validation.normalize_email(Validation.value(attrs, :email))

    with true <- email == preauthorized_email,
         :ok <- Validation.password(password),
         {:ok, session, tenant} <- Sessions.lock_active_guest(guest_subject) do
      changes = %{
        external_subject: "local:#{email}",
        display_name:
          Validation.value(attrs, :display_name) ||
            session.user.display_name,
        email: email,
        password_hash: Password.hash(password)
      }

      with :ok <-
             session.user
             |> User.guest_conversion_changeset(changes)
             |> valid_changeset() do
        converted_user =
          session.user
          |> User.guest_conversion_changeset(changes)
          |> update_or_validation_error(effects)

        revoked_at = Persistence.now()

        session
        |> Session.changeset(%{revoked_at: revoked_at})
        |> update_or_rollback()

        session.device
        |> Device.changeset(%{revoked_at: revoked_at})
        |> update_or_rollback()

        CallLifecycleCommand.sessions_revoked(
          session.tenant_id,
          [session.id],
          "guest_converted"
        )
        |> effects.revoke_identity_access.()

        device_attrs = Validation.value(attrs, :device) || %{}

        device =
          %Device{id: Ecto.UUID.generate()}
          |> Device.changeset(%{
            tenant_id: converted_user.tenant_id,
            user_id: converted_user.id,
            name:
              Validation.value(device_attrs, :name) ||
                Validation.value(attrs, :device_name) ||
                "Account browser",
            platform:
              Validation.value(device_attrs, :platform) ||
                Validation.value(attrs, :device_platform) || "web",
            last_seen_at: revoked_at
          })
          |> insert_or_rollback()

        {session, refresh_token} =
          Sessions.create_or_rollback(converted_user, device)

        Audit.record(%{
          tenant_id: converted_user.tenant_id,
          actor_user_id: converted_user.id,
          action: "guest_identity.convert",
          resource_type: "user",
          resource_id: converted_user.id,
          metadata: %{
            previous_session_id: Validation.value(guest_subject, :session_id),
            replacement_session_id: session.id
          },
          request_id: Validation.optional_request_id(Validation.value(guest_subject, :request_id))
        })
        |> Persistence.audit_or_rollback()

        {:ok,
         CommsCore.Accounts.Projector.authentication(%{
           tenant: tenant,
           user: converted_user,
           device: device,
           session: session,
           refresh_token: refresh_token,
           conversation: nil
         })}
      end
    else
      false -> {:error, :guest_account_conversion_email_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp convert_ephemeral_in_transaction(attrs, guest_subject, effects) do
    password = Validation.value(attrs, :password)
    email = Validation.normalize_email(Validation.value(attrs, :email))

    with :ok <- Validation.password(password),
         {:ok, session, tenant} <- Sessions.lock_active_guest(guest_subject),
         true <- session.user.access_scope == :conversation_only do
      changes = %{
        external_subject: "local:#{email}",
        display_name:
          Validation.value(attrs, :display_name) ||
            session.user.display_name,
        email: email,
        password_hash: Password.hash(password)
      }

      with :ok <-
             session.user
             |> User.ephemeral_guest_conversion_changeset(changes)
             |> valid_changeset() do
        converted_user =
          session.user
          |> User.ephemeral_guest_conversion_changeset(changes)
          |> update_or_validation_error(effects)

        converted_at = Persistence.now()

        session
        |> Session.changeset(%{revoked_at: converted_at})
        |> update_or_rollback()

        device =
          session.device
          |> Device.changeset(%{last_seen_at: converted_at})
          |> update_or_rollback()

        {replacement_session, refresh_token} =
          Sessions.create_or_rollback(converted_user, device)

        Audit.record(%{
          tenant_id: converted_user.tenant_id,
          actor_user_id: converted_user.id,
          action: "guest_identity.convert_ephemeral",
          resource_type: "user",
          resource_id: converted_user.id,
          metadata: %{
            previous_session_id: Validation.value(guest_subject, :session_id),
            replacement_session_id: replacement_session.id,
            access_scope: "conversation_only"
          },
          request_id: Validation.optional_request_id(Validation.value(guest_subject, :request_id))
        })
        |> Persistence.audit_or_rollback()

        {:ok,
         CommsCore.Accounts.Projector.authentication(%{
           tenant: tenant,
           user: converted_user,
           device: device,
           session: replacement_session,
           refresh_token: refresh_token,
           conversation: nil
         })}
      end
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp valid_changeset(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_changeset(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp normalize_account_result({:error, %Ecto.Changeset{}}, _effects),
    do: {:error, :invalid_guest_account}

  defp normalize_account_result({:error, reason} = result, effects) do
    if effects.validation_error?.(reason),
      do: {:error, :invalid_guest_account},
      else: result
  end

  defp normalize_account_result(result, _effects), do: result

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_validation_error(changeset, effects) do
    case Repo.update(changeset) do
      {:ok, value} ->
        value

      {:error, invalid_changeset} ->
        Repo.rollback(effects.validation_error_from_changeset.(invalid_changeset))
    end
  end
end
