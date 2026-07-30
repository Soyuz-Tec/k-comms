defmodule CommsCore.Accounts.Sessions.Persistence do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Device, PlatformAccess, Session, User}
  alias CommsCore.{Administration, Repo}
  alias CommsCore.Audit

  def get_active(id) when is_binary(id) do
    with {:ok, session, _tenant} <- active_with_tenant(id) do
      {:ok, session}
    end
  end

  def active_with_tenant(id) when is_binary(id) do
    query =
      from(s in Session,
        join: u in assoc(s, :user),
        join: d in assoc(s, :device),
        where:
          s.id == ^id and is_nil(s.revoked_at) and s.expires_at > ^now() and
            s.absolute_expires_at > ^now() and
            u.status == :active and u.account_type == :human and is_nil(d.revoked_at),
        preload: [user: u, device: d]
      )

    with %Session{} = session <- Repo.one(query),
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {:ok, session, tenant}
    else
      _ -> {:error, :session_expired}
    end
  end

  def active_guest_with_tenant(id) when is_binary(id) do
    timestamp = now()

    query =
      from(s in Session,
        join: u in assoc(s, :user),
        join: d in assoc(s, :device),
        where:
          s.id == ^id and s.tenant_id == u.tenant_id and s.user_id == u.id and
            s.tenant_id == d.tenant_id and s.user_id == d.user_id and
            s.device_id == d.id and is_nil(s.revoked_at) and
            s.expires_at > ^timestamp and s.absolute_expires_at > ^timestamp and
            u.status == :active and u.account_type == :guest and
            not is_nil(u.guest_expires_at) and u.guest_expires_at > ^timestamp and
            is_nil(d.revoked_at),
        preload: [user: u, device: d]
      )

    with %Session{} = session <- Repo.one(query),
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {:ok, session, tenant}
    else
      _ -> {:error, :session_expired}
    end
  end

  def active_guest_with_tenant(_id), do: {:error, :session_expired}

  def subject(%Session{} = session, request_id \\ nil) do
    session = Repo.preload(session, [user: :platform_role_grant], force: true)
    platform_access = PlatformAccess.for_subject(session.user)

    Map.merge(
      %{
        tenant_id: session.tenant_id,
        user_id: session.user_id,
        device_id: session.device_id,
        session_id: session.id,
        request_id: request_id,
        account_type: session.user.account_type,
        access_scope: session.user.access_scope,
        guest_expires_at: session.user.guest_expires_at,
        role: session.user.role,
        step_up_at: session.step_up_at
      },
      platform_access
    )
  end

  def lock_active_guest(subject) do
    timestamp = now()

    case subject_identity(subject) do
      {tenant_id, user_id, device_id, session_id}
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) and
             is_binary(session_id) ->
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
                s.id == ^session_id and s.tenant_id == ^tenant_id and
                  s.user_id == ^user_id and s.device_id == ^device_id and
                  is_nil(s.revoked_at) and s.expires_at > ^timestamp and
                  s.absolute_expires_at > ^timestamp and u.status == :active and
                  u.account_type == :guest and not is_nil(u.guest_expires_at) and
                  u.guest_expires_at > ^timestamp and is_nil(d.revoked_at),
              preload: [user: u, device: d],
              lock: "FOR UPDATE"
            )
          )

        with %Session{} = session <- session,
             {:ok, tenant} <- Administration.active_tenant(tenant_id) do
          {:ok, session, tenant}
        else
          nil -> {:error, :session_expired}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :forbidden}
    end
  end

  def upsert_device(user, attrs) do
    requested_id = value(attrs, :id)

    existing =
      if is_binary(requested_id) do
        Repo.get_by(Device, id: requested_id, tenant_id: user.tenant_id, user_id: user.id)
      end

    changes = %{
      tenant_id: user.tenant_id,
      user_id: user.id,
      name: value(attrs, :name) || "Browser",
      platform: value(attrs, :platform) || "web",
      last_seen_at: now(),
      revoked_at: nil
    }

    case existing do
      %Device{} = device -> device |> Device.changeset(changes) |> Repo.update()
      nil -> %Device{} |> Device.changeset(changes) |> Repo.insert()
    end
  end

  def insert_audit!(subject, action, resource_type, resource_id, metadata) do
    %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    }
    |> Audit.record()
    |> audit_or_rollback()
  end

  def transaction_result({:ok, result}), do: {:ok, result}
  def transaction_result({:error, reason}), do: {:error, reason}

  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  def value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp subject_identity(subject) do
    {
      value(subject, :tenant_id),
      value(subject, :user_id),
      value(subject, :device_id),
      value(subject, :session_id)
    }
  end
end
