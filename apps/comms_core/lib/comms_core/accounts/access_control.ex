defmodule CommsCore.Accounts.AccessControl do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessGrant,
    Device,
    PlatformRoleGrant,
    Session,
    User
  }

  alias CommsCore.Administration.{AuthorizationActor, IdentityGrant}
  alias CommsCore.Audit
  alias CommsCore.Audit.Actor
  alias CommsCore.{Administration, Repo}

  @platform_roles PlatformRoleGrant.roles()

  @spec access_grant(map()) :: {:ok, AccessGrant.t()} | {:error, :forbidden}
  def access_grant(subject) when is_map(subject) do
    case subject_identity(subject) do
      {tenant_id, user_id, device_id, session_id}
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) and
             is_binary(session_id) ->
        timestamp = now()

        query =
          from(s in Session,
            join: u in User,
            on: u.id == s.user_id,
            join: d in Device,
            on: d.id == s.device_id,
            left_join: g in PlatformRoleGrant,
            on:
              g.user_id == u.id and g.tenant_id == u.tenant_id and
                g.expires_at > ^timestamp and u.account_type == :human and
                u.access_scope == :workspace,
            where:
              s.id == ^session_id and s.tenant_id == ^tenant_id and s.user_id == ^user_id and
                s.device_id == ^device_id and u.id == ^user_id and
                u.tenant_id == ^tenant_id and u.status == :active and
                (u.account_type == :human or
                   (u.account_type == :guest and not is_nil(u.guest_expires_at) and
                      u.guest_expires_at > ^timestamp)) and d.id == ^device_id and
                d.tenant_id == ^tenant_id and d.user_id == ^user_id and
                is_nil(d.revoked_at) and is_nil(s.revoked_at) and
                s.expires_at > ^timestamp and s.absolute_expires_at > ^timestamp,
            select: %{
              tenant_id: s.tenant_id,
              user_id: s.user_id,
              device_id: s.device_id,
              session_id: s.id,
              account_type: u.account_type,
              access_scope: u.access_scope,
              guest_expires_at: u.guest_expires_at,
              role: u.role,
              step_up_at: s.step_up_at,
              platform_role_grant_id: g.id,
              platform_role: g.role,
              platform_role_expires_at: g.expires_at
            }
          )

        case Repo.one(query) do
          nil ->
            {:error, :forbidden}

          facts ->
            case Administration.active_tenant(facts.tenant_id) do
              {:ok, _tenant} -> {:ok, build_access_grant(facts, subject, timestamp)}
              {:error, :tenant_unavailable} -> {:error, :forbidden}
            end
        end

      _ ->
        {:error, :forbidden}
    end
  end

  def access_grant(_subject), do: {:error, :forbidden}

  @spec lock_access_grant(map()) ::
          {:ok, AccessGrant.t()} | {:error, :forbidden | :transaction_required}
  def lock_access_grant(subject) when is_map(subject) do
    if Repo.in_transaction?() do
      case subject_identity(subject) do
        {tenant_id, user_id, device_id, session_id}
        when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) and
               is_binary(session_id) ->
          timestamp = now()

          with %Session{} <-
                 Repo.one(
                   from(session in Session,
                     where:
                       session.id == ^session_id and session.tenant_id == ^tenant_id and
                         session.user_id == ^user_id and session.device_id == ^device_id and
                         is_nil(session.revoked_at) and session.expires_at > ^timestamp and
                         session.absolute_expires_at > ^timestamp,
                     lock: "FOR SHARE"
                   )
                 ),
               {:ok, %AccessGrant{} = grant} <- access_grant(subject) do
            {:ok, grant}
          else
            _ -> {:error, :forbidden}
          end

        _ ->
          {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock_access_grant(_subject), do: {:error, :forbidden}

  @spec resolve_access(map()) :: {:ok, IdentityGrant.t()} | {:error, :forbidden}
  def resolve_access(subject) when is_map(subject) do
    with {:ok, %AccessGrant{} = grant} <- access_grant(subject) do
      {:ok,
       %IdentityGrant{
         tenant_id: grant.tenant_id,
         user_id: grant.user_id,
         role: grant.role,
         step_up_recent?: grant.step_up_recent?
       }}
    end
  end

  def resolve_access(_subject), do: {:error, :forbidden}

  @spec resolve_authorization_actor(map()) ::
          {:ok, AuthorizationActor.t()} | {:error, :unknown_authorization_actor}
  def resolve_authorization_actor(subject) do
    with {:ok, %Actor{} = actor} <- authorization_audit_actor(subject) do
      {:ok,
       %AuthorizationActor{
         tenant_id: actor.tenant_id,
         user_id: actor.user_id,
         request_id: actor.request_id
       }}
    end
  end

  @spec authorization_audit_actor(map()) ::
          {:ok, Actor.t()} | {:error, :unknown_authorization_actor}
  def authorization_audit_actor(subject) when is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %User{} <- Repo.get_by(User, id: user_id, tenant_id: tenant_id) do
      {:ok,
       %Actor{
         tenant_id: tenant_id,
         user_id: user_id,
         request_id: audit_request_id(subject)
       }}
    else
      _ -> {:error, :unknown_authorization_actor}
    end
  end

  def authorization_audit_actor(_subject), do: {:error, :unknown_authorization_actor}

  @spec audit_authorization_denial(atom(), map(), term()) :: {:error, term()}
  def audit_authorization_denial(action, subject, reason)
      when is_atom(action) and is_map(subject) do
    case authorization_audit_actor(subject) do
      {:ok, actor} -> Audit.authorization_denied(action, actor, reason)
      {:error, :unknown_authorization_actor} -> {:error, reason}
    end
  end

  def audit_authorization_denial(_action, _subject, reason), do: {:error, reason}

  @spec authorize_receive_user_events(map(), map()) :: :ok | {:error, :forbidden}
  def authorize_receive_user_events(subject, resource)
      when is_map(subject) and is_map(resource) do
    with {:ok, %AccessGrant{user_id: user_id}} <- access_grant(subject),
         ^user_id <- value(resource, :user_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_receive_user_events(_subject, _resource), do: {:error, :forbidden}

  @spec authorize_administer_users(map()) :: :ok | {:error, :forbidden}
  def authorize_administer_users(subject) when is_map(subject) do
    case access_grant(subject) do
      {:ok, %AccessGrant{access_scope: :workspace, role: role}}
      when role in [:owner, :admin] ->
        :ok

      _ ->
        deny_privileged(:administer_tenant, subject, :forbidden)
    end
  end

  def authorize_administer_users(_subject), do: {:error, :forbidden}

  @spec authorize_manage_user_lifecycle(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_user_lifecycle(subject) when is_map(subject) do
    authorize_tenant_role_with_step_up(
      :manage_user_lifecycle,
      subject,
      [:owner, :admin]
    )
  end

  def authorize_manage_user_lifecycle(_subject), do: {:error, :forbidden}

  @spec authorize_manage_sessions(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_sessions(subject) when is_map(subject) do
    authorize_tenant_role_with_step_up(
      :manage_sessions,
      subject,
      [:owner, :security_admin]
    )
  end

  def authorize_manage_sessions(_subject), do: {:error, :forbidden}

  @spec authorize_view_platform_operations(map()) :: :ok | {:error, :forbidden}
  def authorize_view_platform_operations(subject) when is_map(subject) do
    case access_grant(subject) do
      {:ok,
       %AccessGrant{
         access_scope: :workspace,
         platform_role: role,
         platform_claim_verified?: true
       }}
      when role in @platform_roles ->
        :ok

      _ ->
        deny_privileged(:view_platform_operations, subject, :forbidden)
    end
  end

  def authorize_view_platform_operations(_subject), do: {:error, :forbidden}

  @spec authorize_operate_platform(map()) :: :ok | {:error, :forbidden}
  def authorize_operate_platform(subject) when is_map(subject) do
    case access_grant(subject) do
      {:ok,
       %AccessGrant{
         access_scope: :workspace,
         platform_role: :platform_operator,
         platform_claim_verified?: true
       }} ->
        :ok

      _ ->
        deny_privileged(:operate_platform, subject, :forbidden)
    end
  end

  def authorize_operate_platform(_subject), do: {:error, :forbidden}

  defp subject_identity(subject) do
    {
      value(subject, :tenant_id),
      value(subject, :user_id),
      value(subject, :device_id),
      value(subject, :session_id)
    }
  end

  defp build_access_grant(facts, subject, timestamp) do
    %AccessGrant{
      tenant_id: facts.tenant_id,
      user_id: facts.user_id,
      device_id: facts.device_id,
      session_id: facts.session_id,
      request_id: value(subject, :request_id),
      account_type: facts.account_type,
      access_scope: facts.access_scope,
      guest_expires_at: facts.guest_expires_at,
      role: facts.role,
      step_up_at: facts.step_up_at,
      step_up_recent?: recent_step_up_at?(facts.step_up_at, timestamp),
      platform_role_grant_id: facts.platform_role_grant_id,
      platform_role: facts.platform_role,
      platform_role_expires_at: facts.platform_role_expires_at,
      platform_claim_verified?: platform_claim_verified?(facts, subject)
    }
  end

  defp recent_step_up_at?(%DateTime{} = step_up_at, timestamp) do
    ttl = Application.get_env(:comms_core, :step_up_ttl_seconds, 300)
    threshold = DateTime.add(timestamp, -ttl, :second)
    DateTime.compare(step_up_at, threshold) != :lt
  end

  defp recent_step_up_at?(_step_up_at, _timestamp), do: false

  defp platform_claim_verified?(
         %{
           platform_role_grant_id: grant_id,
           platform_role: role,
           platform_role_expires_at: %DateTime{} = expires_at
         },
         subject
       )
       when is_binary(grant_id) and role in @platform_roles do
    value(subject, :platform_role_grant_id) == grant_id and
      normalized_platform_role(value(subject, :platform_role)) == role and
      platform_deadline_matches?(value(subject, :platform_role_expires_at), expires_at)
  end

  defp platform_claim_verified?(_facts, _subject), do: false

  defp normalized_platform_role(role) when role in @platform_roles, do: role

  defp normalized_platform_role(role) when is_binary(role) do
    Enum.find(@platform_roles, &(Atom.to_string(&1) == role))
  end

  defp normalized_platform_role(_role), do: nil

  defp platform_deadline_matches?(%DateTime{} = claimed, %DateTime{} = persisted),
    do: DateTime.compare(claimed, persisted) == :eq

  defp platform_deadline_matches?(_claimed, _persisted), do: false

  defp authorize_tenant_role_with_step_up(action, subject, allowed_roles) do
    case access_grant(subject) do
      {:ok, %AccessGrant{access_scope: :workspace} = grant} ->
        cond do
          not Enum.member?(allowed_roles, grant.role) ->
            deny_privileged(action, subject, :forbidden)

          grant.step_up_recent? ->
            :ok

          true ->
            deny_privileged(action, subject, :step_up_required)
        end

      _ ->
        deny_privileged(action, subject, :forbidden)
    end
  end

  defp deny_privileged(action, subject, reason) do
    audit_authorization_denial(action, subject, reason)
  end

  defp audit_request_id(subject) do
    case value(subject, :request_id) do
      request_id when is_binary(request_id) -> request_id
      _ -> nil
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
