defmodule CommsCore.Accounts.GuestIdentities.SessionLifecycle do
  @moduledoc false

  import Ecto.Query

  import CommsCore.Accounts.GuestIdentities.Validation,
    only: [ephemeral_conversion_subject?: 1, optional_request_id: 1, value: 2]

  alias CommsCore.Accounts.{
    CallLifecycleCommand,
    Device,
    Directory,
    Session,
    Sessions,
    User
  }

  alias CommsCore.{AdmissionQuotas, Audit, Repo}

  @ephemeral_guest_authority_max_seconds 86_400

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

  @spec extend_ephemeral_authority(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok,
           %{
             tenant_id: Ecto.UUID.t(),
             user_id: Ecto.UUID.t(),
             session_id: Ecto.UUID.t(),
             expires_at: DateTime.t()
           }}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  def extend_ephemeral_authority(session_id, deadline) when is_binary(session_id) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not valid_uuid?(session_id) ->
        {:error, :session_expired}

      true ->
        with {:ok, deadline} <- normalize_ephemeral_deadline(deadline),
             {:ok, receipt} <-
               extend_ephemeral_authority_in_transaction(session_id, deadline) do
          {:ok, receipt}
        end
    end
  end

  def extend_ephemeral_authority(_session_id, _deadline) do
    if Repo.in_transaction?(),
      do: {:error, :session_expired},
      else: {:error, :transaction_required}
  end

  @spec ensure_ephemeral_authority(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok,
           %{
             tenant_id: Ecto.UUID.t(),
             user_id: Ecto.UUID.t(),
             session_id: Ecto.UUID.t(),
             expires_at: DateTime.t()
           }}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  def ensure_ephemeral_authority(session_id, deadline) when is_binary(session_id) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not valid_uuid?(session_id) ->
        {:error, :session_expired}

      true ->
        with {:ok, deadline} <- normalize_ephemeral_deadline(deadline),
             {:ok, receipt} <-
               ensure_ephemeral_authority_in_transaction(session_id, deadline) do
          {:ok, receipt}
        end
    end
  end

  def ensure_ephemeral_authority(_session_id, _deadline) do
    if Repo.in_transaction?(),
      do: {:error, :session_expired},
      else: {:error, :transaction_required}
  end

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

      not ephemeral_conversion_subject?(command) ->
        {:error, :forbidden}

      true ->
        with {:ok, user_id} <- cast_uuid_value(value(command, :user_id)),
             {:ok, session_id} <- cast_uuid_value(value(command, :session_id)),
             {:ok, deadline} <-
               normalize_ephemeral_deadline(value(command, :expires_at)) do
          resume_ephemeral_in_transaction(
            user_id,
            session_id,
            value(command, :device) || %{},
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

  @spec revoke_session(Ecto.UUID.t(), String.t(), map()) ::
          :ok | {:error, :not_found | :invalid_reason | term()}
  def revoke_session(session_id, reason, effects)
      when is_binary(session_id) and is_binary(reason) and is_map(effects) do
    reason = String.trim(reason)

    if reason == "" or String.length(reason) > 160 do
      {:error, :invalid_reason}
    else
      run_transaction_aware(fn -> revoke_session_in_transaction(session_id, reason, effects) end)
    end
  end

  def revoke_session(_session_id, _reason, _effects), do: {:error, :invalid_reason}

  defp provision_in_transaction(attrs, effects) do
    created_at = now()
    tenant_id = value(attrs, :tenant_id)

    with {:ok, _uuid} <- Ecto.UUID.cast(tenant_id),
         {:ok, guest_expires_at} <-
           normalize_expiry(value(attrs, :expires_at), created_at),
         {:ok, tenant} <- effects.active_tenant.(tenant_id),
         {:ok, policy} <- AdmissionQuotas.locked_policy(tenant_id),
         :ok <- Directory.ensure_active_user_capacity(tenant_id, policy),
         {:ok, user_id} <- guest_user_id(value(attrs, :user_id)) do
      device_attrs = value(attrs, :device) || %{}

      user_changeset =
        User.guest_changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: "guest:#{user_id}",
          display_name: value(attrs, :display_name),
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
                value(device_attrs, :name) || value(attrs, :device_name) ||
                  "Guest browser",
              platform: value(device_attrs, :platform) || value(attrs, :device_platform) || "web",
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
            request_id: optional_request_id(value(attrs, :request_id))
          })
          |> audit_or_rollback()

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

  defp extend_ephemeral_authority_in_transaction(session_id, deadline) do
    timestamp = now()
    session = lock_active_ephemeral_session(session_id, timestamp)

    case session do
      nil ->
        {:error, :session_expired}

      %Session{} = active_session ->
        rolling_deadline =
          timestamp
          |> DateTime.add(session_ttl_seconds(), :second)
          |> earlier_deadline(deadline)

        user_changeset =
          User.guest_expiration_changeset(active_session.user, deadline)

        session_changeset =
          Session.ephemeral_guest_authority_changeset(active_session, %{
            expires_at: rolling_deadline,
            absolute_expires_at: deadline,
            last_used_at: timestamp
          })

        device_changeset =
          Device.changeset(active_session.device, %{last_seen_at: timestamp})

        with :ok <- valid_ephemeral_authority_changeset(user_changeset),
             :ok <- valid_ephemeral_authority_changeset(session_changeset),
             :ok <- valid_ephemeral_authority_changeset(device_changeset) do
          _user = update_or_rollback(user_changeset)
          updated_session = update_or_rollback(session_changeset)
          _device = update_or_rollback(device_changeset)

          {:ok,
           %{
             tenant_id: updated_session.tenant_id,
             user_id: updated_session.user_id,
             session_id: updated_session.id,
             expires_at: deadline
           }}
        end
    end
  end

  defp ensure_ephemeral_authority_in_transaction(session_id, deadline) do
    timestamp = now()

    case lock_active_ephemeral_session(session_id, timestamp) do
      nil ->
        {:error, :session_expired}

      %Session{} = active_session ->
        absolute_deadline = later_deadline(active_session.absolute_expires_at, deadline)
        user_deadline = later_deadline(active_session.user.guest_expires_at, deadline)

        rolling_deadline =
          timestamp
          |> DateTime.add(session_ttl_seconds(), :second)
          |> earlier_deadline(absolute_deadline)
          |> later_deadline(active_session.expires_at)

        if DateTime.compare(rolling_deadline, deadline) == :lt do
          {:error, :invalid_ephemeral_guest_deadline}
        else
          user_changeset =
            User.guest_expiration_changeset(active_session.user, user_deadline)

          session_changeset =
            Session.ephemeral_guest_authority_changeset(active_session, %{
              expires_at: rolling_deadline,
              absolute_expires_at: absolute_deadline,
              last_used_at: timestamp
            })

          device_changeset =
            Device.changeset(active_session.device, %{last_seen_at: timestamp})

          with :ok <- valid_ephemeral_authority_changeset(user_changeset),
               :ok <- valid_ephemeral_authority_changeset(session_changeset),
               :ok <- valid_ephemeral_authority_changeset(device_changeset) do
            _user = update_or_rollback(user_changeset)
            updated_session = update_or_rollback(session_changeset)
            _device = update_or_rollback(device_changeset)

            {:ok,
             %{
               tenant_id: updated_session.tenant_id,
               user_id: updated_session.user_id,
               session_id: updated_session.id,
               expires_at: deadline
             }}
          end
        end
    end
  end

  defp lock_active_ephemeral_session(session_id, timestamp) do
    Repo.one(
      from(s in Session,
        join: u in User,
        on: u.id == s.user_id and u.tenant_id == s.tenant_id,
        join: d in Device,
        on:
          d.id == s.device_id and d.user_id == s.user_id and
            d.tenant_id == s.tenant_id,
        where:
          s.id == ^session_id and is_nil(s.revoked_at) and
            s.expires_at > ^timestamp and s.absolute_expires_at > ^timestamp and
            u.status == :active and u.account_type == :guest and
            u.access_scope == :conversation_only and not is_nil(u.guest_expires_at) and
            u.guest_expires_at > ^timestamp and is_nil(d.revoked_at),
        preload: [user: u, device: d],
        lock: "FOR UPDATE"
      )
    )
  end

  defp resume_ephemeral_in_transaction(
         user_id,
         session_id,
         device_attrs,
         deadline,
         effects
       ) do
    timestamp = now()

    session =
      Repo.one(
        from(s in Session,
          join: u in User,
          on: u.id == s.user_id and u.tenant_id == s.tenant_id,
          join: d in Device,
          on:
            d.id == s.device_id and d.user_id == s.user_id and
              d.tenant_id == s.tenant_id,
          where:
            s.id == ^session_id and s.user_id == ^user_id and is_nil(s.revoked_at) and
              s.expires_at > ^timestamp and s.absolute_expires_at > ^timestamp and
              u.status == :active and u.account_type == :guest and
              u.access_scope == :conversation_only and not is_nil(u.guest_expires_at) and
              u.guest_expires_at > ^timestamp and is_nil(d.revoked_at),
          preload: [user: u, device: d],
          lock: "FOR UPDATE"
        )
      )

    case session do
      nil ->
        {:error, :session_expired}

      %Session{} = active_session ->
        if DateTime.compare(deadline, active_session.user.guest_expires_at) == :lt do
          {:error, :invalid_ephemeral_guest_deadline}
        else
          with {:ok, tenant} <- effects.active_tenant.(active_session.tenant_id) do
            user_changeset =
              active_session.user
              |> User.guest_expiration_changeset(deadline)

            device_changeset =
              active_session.device
              |> Device.changeset(ephemeral_resume_device_changes(device_attrs, timestamp))

            with :ok <- valid_ephemeral_resume_changeset(user_changeset),
                 :ok <- valid_ephemeral_resume_changeset(device_changeset) do
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
              |> audit_or_rollback()

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
  end

  defp revoke_session_in_transaction(session_id, reason, effects) do
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
        expire_user!(revoked_session.user, now())
        :ok

      %Session{} = active_session ->
        revoked_at = now()
        expire_user!(active_session.user, revoked_at)

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
        |> audit_or_rollback()

        :ok
    end
  end

  defp expire_user!(%User{account_type: :guest} = user, timestamp) do
    if DateTime.compare(user.guest_expires_at, timestamp) == :gt do
      user
      |> User.guest_expiration_changeset(timestamp)
      |> update_or_rollback()
    else
      user
    end
  end

  defp earlier_deadline(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp later_deadline(first, second) do
    if DateTime.compare(first, second) == :lt, do: second, else: first
  end

  defp session_ttl_seconds,
    do: Application.get_env(:comms_core, :session_ttl_seconds, 2_592_000) |> max(0)

  defp ephemeral_resume_device_changes(attrs, timestamp) when is_map(attrs) do
    %{last_seen_at: timestamp}
    |> maybe_put(:name, value(attrs, :name))
    |> maybe_put(:platform, value(attrs, :platform))
  end

  defp ephemeral_resume_device_changes(_attrs, timestamp), do: %{last_seen_at: timestamp}

  defp normalize_expiry(value, timestamp) do
    with {:ok, expiry} <- cast_datetime(value),
         true <- DateTime.compare(expiry, timestamp) == :gt,
         true <- DateTime.diff(expiry, timestamp, :second) <= guest_session_max_ttl_seconds() do
      {:ok, expiry}
    else
      _ -> {:error, :invalid_guest_expiry}
    end
  end

  defp normalize_ephemeral_deadline(value) do
    timestamp = now()

    with {:ok, deadline} <- cast_datetime(value),
         true <- DateTime.compare(deadline, timestamp) == :gt,
         seconds when seconds <= @ephemeral_guest_authority_max_seconds <-
           DateTime.diff(deadline, timestamp, :second) do
      {:ok, deadline}
    else
      _ -> {:error, :invalid_ephemeral_guest_deadline}
    end
  end

  defp cast_datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp cast_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp cast_datetime(_value), do: {:error, :invalid_datetime}

  defp guest_user_id(nil), do: {:ok, Ecto.UUID.generate()}

  defp guest_user_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_guest_identity}
    end
  end

  defp guest_user_id(_value), do: {:error, :invalid_guest_identity}

  defp guest_session_max_ttl_seconds do
    Application.get_env(:comms_core, :guest_session_max_ttl_seconds, 86_400)
    |> max(900)
    |> min(86_400)
  end

  defp valid_ephemeral_authority_changeset(%Ecto.Changeset{valid?: true}), do: :ok

  defp valid_ephemeral_authority_changeset(%Ecto.Changeset{}),
    do: {:error, :invalid_ephemeral_guest_deadline}

  defp valid_ephemeral_resume_changeset(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_ephemeral_resume_changeset(%Ecto.Changeset{}), do: {:error, :invalid_guest_identity}

  defp normalize_identity_result({:error, %Ecto.Changeset{}}),
    do: {:error, :invalid_guest_identity}

  defp normalize_identity_result(result), do: result

  defp run_transaction_aware(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      fun.()
    else
      case Repo.transaction(fn ->
             case fun.() do
               {:error, reason} -> Repo.rollback(reason)
               result -> result
             end
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

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

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp cast_uuid_value(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp cast_uuid_value(_value), do: {:error, :invalid_uuid}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
