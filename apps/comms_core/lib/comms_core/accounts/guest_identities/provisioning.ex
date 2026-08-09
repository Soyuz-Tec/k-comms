defmodule CommsCore.Accounts.GuestIdentities.Provisioning do
  @moduledoc false

  alias CommsCore.Accounts.{Device, Directory, Sessions, User}
  alias CommsCore.Accounts.GuestIdentities.{Persistence, Validation}
  alias CommsCore.{AdmissionQuotas, Audit, Repo}

  @spec provision(map(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :transaction_required
             | :tenant_unavailable
             | :invalid_guest_expiry
             | :active_user_quota_exceeded
             | :invalid_guest_identity}
  def provision(attrs, effects) when is_map(attrs) and is_map(effects) do
    if Repo.in_transaction?() do
      attrs
      |> provision_in_transaction(effects)
      |> normalize_identity_result()
    else
      {:error, :transaction_required}
    end
  end

  def provision(_attrs, _effects), do: {:error, :transaction_required}

  defp provision_in_transaction(attrs, effects) do
    created_at = Persistence.now()
    tenant_id = Validation.value(attrs, :tenant_id)

    with {:ok, _uuid} <- Ecto.UUID.cast(tenant_id),
         {:ok, guest_expires_at} <-
           normalize_expiry(Validation.value(attrs, :expires_at), created_at),
         {:ok, tenant} <- effects.active_tenant.(tenant_id),
         {:ok, policy} <- AdmissionQuotas.locked_policy(tenant_id),
         :ok <- Directory.ensure_active_user_capacity(tenant_id, policy),
         {:ok, user_id} <- guest_user_id(Validation.value(attrs, :user_id)) do
      device_attrs = Validation.value(attrs, :device) || %{}

      user_changeset =
        User.guest_changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: "guest:#{user_id}",
          display_name: Validation.value(attrs, :display_name),
          guest_expires_at: guest_expires_at
        })

      case Repo.insert(user_changeset) do
        {:ok, user} ->
          device =
            %Device{id: Ecto.UUID.generate()}
            |> Device.changeset(%{
              tenant_id: tenant_id,
              user_id: user.id,
              name:
                Validation.value(device_attrs, :name) ||
                  Validation.value(attrs, :device_name) || "Guest browser",
              platform:
                Validation.value(device_attrs, :platform) ||
                  Validation.value(attrs, :device_platform) || "web",
              last_seen_at: created_at
            })
            |> insert_or_rollback()

          {session, refresh_token} =
            Sessions.create_guest_or_rollback(user, device, guest_expires_at, created_at)

          Audit.record(%{
            tenant_id: tenant_id,
            actor_user_id: user.id,
            action: "guest_identity.provision",
            resource_type: "user",
            resource_id: user.id,
            metadata: %{
              guest_expires_at: DateTime.to_iso8601(guest_expires_at),
              device_id: device.id
            },
            request_id:
              attrs
              |> Validation.value(:request_id)
              |> Validation.optional_request_id()
          })
          |> Persistence.audit_or_rollback()

          {:ok,
           CommsCore.Accounts.Projector.authentication(%{
             tenant: tenant,
             user: user,
             device: device,
             session: session,
             refresh_token: refresh_token,
             conversation: nil
           })}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      :error -> {:error, :tenant_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_expiry(value, timestamp) do
    with {:ok, expiry} <- Validation.datetime(value),
         true <- DateTime.compare(expiry, timestamp) == :gt,
         true <- DateTime.diff(expiry, timestamp, :second) <= guest_session_max_ttl_seconds() do
      {:ok, expiry}
    else
      _ -> {:error, :invalid_guest_expiry}
    end
  end

  defp guest_user_id(nil), do: {:ok, Ecto.UUID.generate()}

  defp guest_user_id(value) do
    case Validation.uuid(value) do
      {:ok, id} -> {:ok, id}
      {:error, :invalid_uuid} -> {:error, :invalid_guest_identity}
    end
  end

  defp guest_session_max_ttl_seconds do
    Application.get_env(:comms_core, :guest_session_max_ttl_seconds, 86_400)
    |> max(900)
    |> min(86_400)
  end

  defp normalize_identity_result({:error, %Ecto.Changeset{}}),
    do: {:error, :invalid_guest_identity}

  defp normalize_identity_result(result), do: result

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
