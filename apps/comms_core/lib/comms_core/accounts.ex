defmodule CommsCore.Accounts do
  @behaviour CommsCore.Administration.AuthorizationActorPort
  @behaviour CommsCore.Administration.IdentityAccessPort
  @behaviour CommsCore.Administration.InvitationIdentityPort

  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessGrant,
    ConversationBootstrapPort,
    Device,
    InitialConversationCommand,
    NotificationCommand,
    NotificationRecipient,
    NotificationPort,
    PlatformAccess,
    PlatformRoleGrant,
    Session,
    SocketTicket,
    Tenant,
    User
  }

  alias CommsCore.Audit
  alias CommsCore.Audit.Actor

  alias CommsCore.Administration.{
    AdmissionPolicy,
    AuthorizationActor,
    IdentityGrant,
    InvitationIdentityAuthorization,
    InvitedIdentityReceipt,
    InvitedUserCommand
  }

  alias CommsCore.{
    Administration,
    AdmissionQuotas,
    AudioCalls,
    Repo
  }

  alias CommsCore.Security.Password

  @session_bytes 32
  @bootstrap_lock_key 1_449_769_383
  @platform_roles PlatformRoleGrant.roles()
  @platform_role_min_ttl_seconds 300
  @platform_role_max_ttl_seconds 28_800

  @doc """
  Resolves an active human session into persistence-free authorization facts.

  The tenant, user, device, and session identifiers must describe the same
  active identity. A platform grant is returned as verified only when the
  subject carries the exact current grant id, role, and expiry.
  """
  @spec access_grant(map()) :: {:ok, AccessGrant.t()} | {:error, :forbidden}
  def access_grant(subject) when is_map(subject) do
    case subject_identity(subject) do
      {tenant_id, user_id, device_id, session_id}
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) and
             is_binary(session_id) ->
        timestamp = now()

        query =
          from(s in Session,
            join: t in Tenant,
            on: t.id == s.tenant_id,
            join: u in User,
            on: u.id == s.user_id,
            join: d in Device,
            on: d.id == s.device_id,
            left_join: g in PlatformRoleGrant,
            on:
              g.user_id == u.id and g.tenant_id == u.tenant_id and
                g.expires_at > ^timestamp,
            where:
              s.id == ^session_id and s.tenant_id == ^tenant_id and s.user_id == ^user_id and
                s.device_id == ^device_id and t.id == ^tenant_id and t.status == :active and
                u.id == ^user_id and u.tenant_id == ^tenant_id and u.status == :active and
                u.account_type == :human and d.id == ^device_id and d.tenant_id == ^tenant_id and
                d.user_id == ^user_id and is_nil(d.revoked_at) and is_nil(s.revoked_at) and
                s.expires_at > ^timestamp and s.absolute_expires_at > ^timestamp,
            select: %{
              tenant_id: s.tenant_id,
              user_id: s.user_id,
              device_id: s.device_id,
              session_id: s.id,
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
            {:ok, build_access_grant(facts, subject, timestamp)}
        end

      _ ->
        {:error, :forbidden}
    end
  end

  def access_grant(_subject), do: {:error, :forbidden}

  @impl CommsCore.Administration.IdentityAccessPort
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

  @impl CommsCore.Administration.AuthorizationActorPort
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

  @doc """
  Counts active IdentityAccess users for the tenant without exposing User
  persistence.
  """
  @spec active_user_count(Ecto.UUID.t()) :: non_neg_integer()
  def active_user_count(tenant_id) when is_binary(tenant_id) do
    User
    |> where([user], user.tenant_id == ^tenant_id and user.status == :active)
    |> Repo.aggregate(:count)
  end

  @doc """
  Resolves requested user IDs that are active in the exact tenant.

  Human and service identities are both eligible. Results are de-duplicated by
  persistence and returned in user-id order.
  """
  @spec resolve_active_user_ids(String.t(), [String.t()]) :: [String.t()]
  def resolve_active_user_ids(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    User
    |> where(
      [user],
      user.tenant_id == ^tenant_id and user.id in ^user_ids and user.status == :active and
        user.account_type in [:human, :service]
    )
    |> order_by([user], asc: user.id)
    |> select([user], user.id)
    |> Repo.all()
  end

  def resolve_active_user_ids(_tenant_id, _user_ids), do: []

  @doc """
  Resolves requested tenant users into stable identity projections.

  Existing identities are returned regardless of lifecycle status so owner
  contexts can display suspended or erased members without receiving User
  persistence. Results are ordered by display name and then user ID.
  """
  @spec resolve_user_views(String.t(), [String.t()]) :: [CommsCore.Accounts.UserView.t()]
  def resolve_user_views(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    User
    |> where([user], user.tenant_id == ^tenant_id and user.id in ^user_ids)
    |> order_by([user], asc: user.display_name, asc: user.id)
    |> Repo.all()
    |> Enum.map(&CommsCore.Accounts.Projector.user/1)
  end

  def resolve_user_views(_tenant_id, _user_ids), do: []

  @doc """
  Resolves active human users into the minimal projection needed for
  notification delivery.

  Results are scoped to the exact tenant, de-duplicated by persistence, and
  returned in user-id order.
  """
  @spec resolve_notification_recipients(String.t(), [String.t()]) ::
          [NotificationRecipient.t()]
  def resolve_notification_recipients(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    User
    |> where(
      [user],
      user.tenant_id == ^tenant_id and user.id in ^user_ids and user.status == :active and
        user.account_type == :human
    )
    |> order_by([user], asc: user.id)
    |> select([user], %{user_id: user.id, email: user.email})
    |> Repo.all()
    |> Enum.map(&struct!(NotificationRecipient, &1))
  end

  def resolve_notification_recipients(_tenant_id, _user_ids), do: []

  @doc """
  Returns the requested device ids that remain eligible for push delivery.

  Eligibility is owned by IdentityAccess: the user must be an active human and
  each device must belong to that same tenant and user and remain unrevoked.
  """
  @spec notification_eligible_device_ids(String.t(), String.t(), [String.t()]) :: [String.t()]
  def notification_eligible_device_ids(tenant_id, user_id, device_ids)
      when is_binary(tenant_id) and is_binary(user_id) and is_list(device_ids) do
    Device
    |> join(:inner, [device], user in User,
      on: user.id == device.user_id and user.tenant_id == device.tenant_id
    )
    |> where(
      [device, user],
      device.tenant_id == ^tenant_id and device.user_id == ^user_id and
        device.id in ^device_ids and is_nil(device.revoked_at) and user.id == ^user_id and
        user.status == :active and user.account_type == :human
    )
    |> order_by([device, _user], asc: device.id)
    |> select([device, _user], device.id)
    |> Repo.all()
  end

  def notification_eligible_device_ids(_tenant_id, _user_id, _device_ids), do: []

  @doc """
  Locks the exact IdentityAccess authority used to register a push endpoint.

  The caller must already own a database transaction. The active-human user row
  is locked before its unrevoked device row so concurrent identity lifecycle
  changes use a deterministic lock order.
  """
  @spec lock_push_registration_identity(String.t(), String.t(), String.t()) ::
          :ok | {:error, :forbidden | :transaction_required}
  def lock_push_registration_identity(tenant_id, user_id, device_id)
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) do
    if Repo.in_transaction?() do
      with %User{} <-
             Repo.one(
               from(user in User,
                 where:
                   user.id == ^user_id and user.tenant_id == ^tenant_id and
                     user.status == :active and user.account_type == :human,
                 lock: "FOR SHARE"
               )
             ),
           %Device{} <-
             Repo.one(
               from(device in Device,
                 where:
                   device.id == ^device_id and device.tenant_id == ^tenant_id and
                     device.user_id == ^user_id and is_nil(device.revoked_at),
                 lock: "FOR SHARE"
               )
             ) do
        :ok
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock_push_registration_identity(_tenant_id, _user_id, _device_id),
    do: {:error, :forbidden}

  @doc false
  @spec ensure_active_user_capacity(Ecto.UUID.t(), AdmissionPolicy.t(), pos_integer()) ::
          :ok
          | {:error, :active_user_quota_exceeded | :quota_transaction_required}
  def ensure_active_user_capacity(
        tenant_id,
        %AdmissionPolicy{} = policy,
        increment \\ 1
      )
      when is_binary(tenant_id) and is_integer(increment) and increment > 0 do
    if Repo.in_transaction?() do
      AdmissionQuotas.check_active_user_capacity(
        policy,
        active_user_count(tenant_id),
        increment
      )
    else
      {:error, :quota_transaction_required}
    end
  end

  @doc """
  Resolves the verified tenant/user pair used to audit an authorization denial.

  Session, device, tenant, or user activity is deliberately not required: a
  revoked or suspended principal's denied privileged attempt must still be
  attributable. The user must, however, belong to the claimed tenant.
  """
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

  @doc false
  @spec audit_authorization_denial(atom(), map(), term()) :: {:error, term()}
  def audit_authorization_denial(action, subject, reason)
      when is_atom(action) and is_map(subject) do
    case authorization_audit_actor(subject) do
      {:ok, actor} -> Audit.authorization_denied(action, actor, reason)
      {:error, :unknown_authorization_actor} -> {:error, reason}
    end
  end

  def audit_authorization_denial(_action, _subject, reason), do: {:error, reason}

  @doc false
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

  @doc false
  @spec authorize_administer_users(map()) :: :ok | {:error, :forbidden}
  def authorize_administer_users(subject) when is_map(subject) do
    case access_grant(subject) do
      {:ok, %AccessGrant{role: role}} when role in [:owner, :admin] ->
        :ok

      _ ->
        deny_privileged(:administer_tenant, subject, :forbidden)
    end
  end

  def authorize_administer_users(_subject), do: {:error, :forbidden}

  @doc false
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

  @doc false
  @spec authorize_manage_sessions(map()) :: :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_sessions(subject) when is_map(subject) do
    authorize_tenant_role_with_step_up(
      :manage_sessions,
      subject,
      [:owner, :security_admin]
    )
  end

  def authorize_manage_sessions(_subject), do: {:error, :forbidden}

  @doc false
  @spec authorize_view_platform_operations(map()) :: :ok | {:error, :forbidden}
  def authorize_view_platform_operations(subject) when is_map(subject) do
    case access_grant(subject) do
      {:ok,
       %AccessGrant{
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

  @doc false
  @spec authorize_operate_platform(map()) :: :ok | {:error, :forbidden}
  def authorize_operate_platform(subject) when is_map(subject) do
    case access_grant(subject) do
      {:ok,
       %AccessGrant{
         platform_role: :platform_operator,
         platform_claim_verified?: true
       }} ->
        :ok

      _ ->
        deny_privileged(:operate_platform, subject, :forbidden)
    end
  end

  def authorize_operate_platform(_subject), do: {:error, :forbidden}

  # Adapter-facing API. These functions are the stable projection boundary;
  # persistence-returning operations below remain available to owner internals
  # while callers migrate.
  def bootstrap_tenant_view(attrs) do
    with {:ok, result} <- bootstrap_tenant(attrs) do
      {:ok, CommsCore.Accounts.Projector.authentication(result)}
    end
  end

  def authenticate_view(tenant_slug, email, password, device_attrs \\ %{}) do
    authenticate(tenant_slug, email, password, device_attrs)
    |> project_result(&CommsCore.Accounts.Projector.authentication/1)
  end

  def refresh_session_view(token) do
    refresh_session(token) |> project_result(&CommsCore.Accounts.Projector.authentication/1)
  end

  def access_context(session_id, request_id \\ nil) do
    with {:ok, session} <- get_active_session(session_id) do
      {:ok,
       CommsCore.Accounts.Projector.access_context(
         session,
         subject_for_session(session, request_id)
       )}
    end
  end

  def list_tenant_user_views(subject),
    do: subject |> list_tenant_users() |> Enum.map(&CommsCore.Accounts.Projector.user/1)

  def list_admin_user_views(subject) do
    with {:ok, users} <- list_admin_users(subject) do
      {:ok, Enum.map(users, &CommsCore.Accounts.Projector.user(&1, platform_access: true))}
    end
  end

  def update_profile_view(attrs, subject),
    do:
      update_profile(attrs, subject)
      |> project_result(&CommsCore.Accounts.Projector.user(&1, platform_access: true))

  def list_device_views(subject),
    do: subject |> list_devices() |> Enum.map(&CommsCore.Accounts.Projector.device/1)

  def list_session_views(subject),
    do: subject |> list_sessions() |> Enum.map(&CommsCore.Accounts.Projector.session/1)

  def list_user_session_views(user_id, subject) do
    with {:ok, sessions} <- list_user_sessions(user_id, subject) do
      {:ok, Enum.map(sessions, &CommsCore.Accounts.Projector.session/1)}
    end
  end

  def change_user_with_effects_view(id, attrs, subject) do
    with {:ok, result} <- change_user_with_effects(id, attrs, subject) do
      {:ok,
       %{result | user: CommsCore.Accounts.Projector.user(result.user, platform_access: true)}}
    end
  end

  def step_up_view(attrs, subject),
    do: step_up(attrs, subject) |> project_result(&CommsCore.Accounts.Projector.session/1)

  def change_password_command(attrs, subject) do
    with {:ok, result} <- change_password_with_effects(attrs, subject) do
      {:ok, Map.take(result, [:revoked_session_ids])}
    end
  end

  def revoke_device_command(id, subject) do
    with {:ok, result} <- revoke_device(id, subject) do
      {:ok, Map.take(result, [:revoked_session_ids])}
    end
  end

  def revoke_own_session_command(id, subject) do
    with {:ok, _session} <- revoke_own_session(id, subject), do: :ok
  end

  def admin_revoke_session_command(user_id, session_id, attrs, subject) do
    with {:ok, _session} <- admin_revoke_session(user_id, session_id, attrs, subject), do: :ok
  end

  @doc false
  @impl CommsCore.Administration.InvitationIdentityPort
  def validate_invitation_password(password) do
    if Repo.in_transaction?(),
      do: validate_password(password),
      else: {:error, :transaction_required}
  end

  @doc false
  @impl CommsCore.Administration.InvitationIdentityPort
  def authorize_invitation(%InvitationIdentityAuthorization{} = authorization) do
    if Repo.in_transaction?() do
      subject = %{
        tenant_id: authorization.tenant_id,
        user_id: authorization.actor_user_id
      }

      with :ok <- reject_service_identity_email(authorization.tenant_id, authorization.email),
           :ok <- authorize_role_assignment(subject, authorization.role) do
        :ok
      end
    else
      {:error, :transaction_required}
    end
  end

  @doc false
  @impl CommsCore.Administration.InvitationIdentityPort
  def ensure_invitation_identity_available(tenant_id, email)
      when is_binary(tenant_id) and is_binary(email) do
    if Repo.in_transaction?(),
      do: reject_existing_human_identity(tenant_id, email),
      else: {:error, :transaction_required}
  end

  @doc false
  @impl CommsCore.Administration.InvitationIdentityPort
  def enroll_invited_user(%InvitedUserCommand{} = command) do
    if Repo.in_transaction?() do
      with :ok <- reject_existing_human_identity(command.tenant_id, command.email),
           :ok <-
             ensure_active_user_capacity(
               command.tenant_id,
               command.admission_policy
             ),
           {:ok, user} <-
             %User{id: Ecto.UUID.generate()}
             |> User.changeset(%{
               tenant_id: command.tenant_id,
               external_subject: "local:#{command.email}",
               display_name: command.display_name,
               email: command.email,
               password_hash: Password.hash(command.password),
               account_type: :human,
               role: command.role,
               status: :active
             })
             |> Repo.insert() do
        {:ok, invited_identity_receipt(user)}
      end
    else
      {:error, :transaction_required}
    end
  end

  defp invited_identity_receipt(%User{} = user) do
    %InvitedIdentityReceipt{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: user.email,
      account_type: user.account_type,
      role: user.role,
      status: user.status,
      version: user.lock_version
    }
  end

  @doc """
  Erases an IdentityAccess-owned user inside a caller-owned governance transaction.

  The caller supplies the pending user-deletion projection used by the last-owner
  invariant. The operation returns identifiers only and never exposes persistence
  schemas across the owner boundary.
  """
  @spec erase_user_for_governance(map()) ::
          {:ok, %{user_id: Ecto.UUID.t(), revoked_session_ids: [Ecto.UUID.t()]}}
          | {:error,
             :invalid_erasure_command
             | :last_owner_required
             | :not_found
             | :transaction_required
             | Ecto.Changeset.t()}
  def erase_user_for_governance(command) when is_map(command) do
    tenant_id = value(command, :tenant_id)
    user_id = value(command, :user_id)
    pending_deletion_user_ids = value(command, :pending_deletion_user_ids)
    timestamp = value(command, :timestamp)

    cond do
      not valid_governance_erasure_command?(
        tenant_id,
        user_id,
        pending_deletion_user_ids,
        timestamp
      ) ->
        {:error, :invalid_erasure_command}

      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      true ->
        erase_user_for_governance(
          tenant_id,
          user_id,
          Enum.uniq(pending_deletion_user_ids),
          timestamp
        )
    end
  end

  def erase_user_for_governance(_command), do: {:error, :invalid_erasure_command}

  def bootstrap_tenant(attrs) when is_map(attrs) do
    with :ok <- validate_password(value(attrs, :password)) do
      now = now()
      session_deadlines = new_session_deadlines(now)
      tenant_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      device_id = Ecto.UUID.generate()
      conversation_id = Ecto.UUID.generate()
      session_id = Ecto.UUID.generate()
      {refresh_token, refresh_hash} = refresh_token(session_id)

      initial_conversation = %InitialConversationCommand{
        id: conversation_id,
        tenant_id: tenant_id,
        owner_user_id: user_id,
        joined_at: now
      }

      multi =
        Ecto.Multi.new()
        |> Administration.append_bootstrap_tenant(
          :tenant,
          %{
            id: tenant_id,
            name: value(attrs, :tenant_name),
            slug: value(attrs, :tenant_slug)
          }
        )
        |> Ecto.Multi.insert(
          :user,
          User.changeset(%User{id: user_id}, %{
            tenant_id: tenant_id,
            external_subject: "local:#{String.downcase(value(attrs, :email) || "")}",
            display_name: value(attrs, :display_name),
            email: value(attrs, :email),
            password_hash: Password.hash(value(attrs, :password)),
            account_type: :human,
            role: :owner,
            status: :active
          })
        )
        |> Ecto.Multi.insert(
          :device,
          Device.changeset(%Device{id: device_id}, %{
            tenant_id: tenant_id,
            user_id: user_id,
            name: value(attrs, :device_name) || "Initial browser",
            platform: value(attrs, :device_platform) || "web",
            last_seen_at: now
          })
        )
        |> ConversationBootstrapPort.append_initial_channel(
          :conversation,
          initial_conversation
        )
        |> Ecto.Multi.insert(
          :session,
          Session.changeset(%Session{id: session_id}, %{
            tenant_id: tenant_id,
            user_id: user_id,
            device_id: device_id,
            refresh_token_hash: refresh_hash,
            expires_at: session_deadlines.expires_at,
            absolute_expires_at: session_deadlines.absolute_expires_at,
            last_used_at: now
          })
        )
        |> Audit.append(%{
          tenant_id: tenant_id,
          actor_user_id: user_id,
          action: "tenant.bootstrap",
          resource_type: "tenant",
          resource_id: tenant_id,
          metadata: %{initial_conversation_id: conversation_id}
        })

      case Repo.transaction(multi) do
        {:ok, result} ->
          {:ok,
           %{
             tenant: result.tenant,
             user: result.user,
             device: result.device,
             session: result.session,
             refresh_token: refresh_token,
             conversation: result.conversation
           }}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Creates the first tenant owner without creating a browser session.

  The operation is serialized in PostgreSQL so a retried release Job is safe.
  Once a tenant exists, only the same normalized tenant slug and owner email are
  accepted as an idempotent retry; a different bootstrap identity fails closed.
  """
  def bootstrap_tenant_once(attrs) when is_map(attrs) do
    password = value(attrs, :password)

    with :ok <- validate_password(password) do
      identity = bootstrap_identity(attrs)
      password_hash = Password.hash(password)

      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT pg_advisory_xact_lock($1::bigint)",
          [@bootstrap_lock_key]
        )

        case Administration.get_bootstrap_tenant_by_slug(identity.tenant_slug) do
          %{id: _id} = tenant ->
            existing_bootstrap(tenant, identity)

          nil ->
            if Administration.any_tenant?() do
              Repo.rollback(:bootstrap_identity_conflict)
            else
              create_one_time_bootstrap(attrs, identity, password_hash)
            end
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_user(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    password = value(attrs, :password)
    email = value(attrs, :email) |> to_string() |> String.trim() |> String.downcase()
    user_id = Ecto.UUID.generate()

    with :ok <- reject_platform_role_attribute(attrs),
         :ok <- reject_service_account_attribute(attrs),
         {:ok, requested_role} <- requested_role(attrs),
         :ok <- authorize_manage_user_lifecycle(subject),
         :ok <- reject_service_identity_email(tenant_id, email),
         :ok <- authorize_role_assignment(subject, requested_role),
         :ok <- validate_password(password) do
      user_changeset =
        User.changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: value(attrs, :external_subject) || "local:#{email}",
          display_name: value(attrs, :display_name),
          email: email,
          password_hash: Password.hash(password),
          account_type: :human,
          role: requested_role,
          status: :active
        })

      Ecto.Multi.new()
      |> Ecto.Multi.run(:admission_quota, fn _repo, _changes ->
        with {:ok, policy} <- AdmissionQuotas.locked_policy(tenant_id),
             :ok <- ensure_active_user_capacity(tenant_id, policy) do
          {:ok, :admitted}
        end
      end)
      |> Ecto.Multi.insert(:user, user_changeset)
      |> Audit.append(%{
        tenant_id: tenant_id,
        actor_user_id: value(subject, :user_id),
        action: "user.create",
        resource_type: "user",
        resource_id: user_id,
        metadata: %{email: email, role: requested_role},
        request_id: value(subject, :request_id)
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def authenticate(tenant_slug, email, password, device_attrs \\ %{}) do
    normalized_email = email |> to_string() |> String.trim() |> String.downcase()

    query =
      from(u in User,
        join: t in assoc(u, :tenant),
        where:
          t.slug == ^tenant_slug and t.status == :active and u.status == :active and
            u.account_type == :human and
            fragment("lower(?)", u.email) == ^normalized_email,
        preload: [tenant: t]
      )

    with %User{} = user <- Repo.one(query),
         true <- Password.verify(password, user.password_hash),
         {:ok, device} <- upsert_device(user, device_attrs),
         {:ok, session, refresh_token} <- create_session(user, device) do
      {:ok,
       %{
         tenant: user.tenant,
         user: user,
         device: device,
         session: session,
         refresh_token: refresh_token
       }}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def refresh_session(token) when is_binary(token) do
    with {:ok, session_id, secret} <- parse_refresh_token(token) do
      case Repo.transaction(fn ->
             session =
               Repo.one(
                 from(s in Session,
                   where: s.id == ^session_id,
                   lock: "FOR UPDATE"
                 )
               )

             rotate_refresh_session(session, secret)
           end) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :invalid_refresh_token}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  def get_active_session(id) when is_binary(id) do
    query =
      from(s in Session,
        join: t in assoc(s, :tenant),
        join: u in assoc(s, :user),
        join: d in assoc(s, :device),
        where:
          s.id == ^id and is_nil(s.revoked_at) and s.expires_at > ^now() and
            s.absolute_expires_at > ^now() and
            t.status == :active and u.status == :active and u.account_type == :human and
            is_nil(d.revoked_at),
        preload: [tenant: t, user: u, device: d]
      )

    case Repo.one(query) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :session_expired}
    end
  end

  def issue_socket_ticket(subject) when is_map(subject) do
    session_id = value(subject, :session_id)

    with {:ok, session} <- get_active_session(session_id),
         true <- session.tenant_id == value(subject, :tenant_id),
         true <- session.user_id == value(subject, :user_id),
         true <- session.device_id == value(subject, :device_id) do
      ticket_id = Ecto.UUID.generate()
      secret = :crypto.strong_rand_bytes(@session_bytes)
      ticket = "#{ticket_id}.#{Base.url_encode64(secret, padding: false)}"

      ttl =
        Application.get_env(:comms_core, :socket_ticket_ttl_seconds, 60) |> min(120) |> max(10)

      Repo.transaction(fn ->
        prune_socket_tickets!()

        %SocketTicket{id: ticket_id}
        |> SocketTicket.changeset(%{
          tenant_id: session.tenant_id,
          user_id: session.user_id,
          device_id: session.device_id,
          session_id: session.id,
          token_hash: :crypto.hash(:sha256, secret),
          expires_at: DateTime.add(now(), ttl, :second)
        })
        |> insert_or_rollback()

        insert_audit!(subject, "socket_ticket.issue", "session", session.id, %{
          ticket_id: ticket_id,
          expires_in: ttl
        })

        %{ticket: ticket, expires_in: ttl}
      end)
      |> transaction_result()
    else
      _ -> {:error, :invalid_access_token}
    end
  end

  def consume_socket_ticket(ticket) when is_binary(ticket) do
    with {:ok, ticket_id, secret} <- parse_socket_ticket(ticket) do
      Repo.transaction(fn ->
        record =
          Repo.one(from(t in SocketTicket, where: t.id == ^ticket_id, lock: "FOR UPDATE")) ||
            Repo.rollback(:invalid_socket_ticket)

        unless is_nil(record.consumed_at) and DateTime.compare(record.expires_at, now()) == :gt and
                 secure_hash_equals(record.token_hash, secret),
               do: Repo.rollback(:invalid_socket_ticket)

        session =
          case get_active_session(record.session_id) do
            {:ok, %Session{} = session} -> session
            _ -> Repo.rollback(:invalid_socket_ticket)
          end

        unless session.tenant_id == record.tenant_id and session.user_id == record.user_id and
                 session.device_id == record.device_id,
               do: Repo.rollback(:invalid_socket_ticket)

        record
        |> SocketTicket.changeset(%{consumed_at: now()})
        |> update_or_rollback()

        subject = subject_for_session(session, "socket-connect")

        insert_audit!(subject, "socket_ticket.consume", "session", session.id, %{
          ticket_id: record.id
        })

        subject
      end)
      |> transaction_result()
    else
      _ -> {:error, :invalid_socket_ticket}
    end
  end

  def consume_socket_ticket(_ticket), do: {:error, :invalid_socket_ticket}

  def revoke_session(session_id, user_id) do
    Repo.transaction(fn ->
      session =
        Repo.one(
          from(s in Session,
            where: s.id == ^session_id and s.user_id == ^user_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      session |> Session.changeset(%{revoked_at: now()}) |> update_or_rollback()

      audio_revocation_ok!(
        AudioCalls.revoke_for_sessions(session.tenant_id, [session.id], "session_logout")
      )

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def list_tenant_users(subject) do
    tenant_id = value(subject, :tenant_id)

    User
    |> where([u], u.tenant_id == ^tenant_id and u.status != :deleted)
    |> order_by([u], asc: fragment("lower(?)", u.display_name))
    |> preload(:platform_role_grant)
    |> Repo.all()
  end

  def list_admin_users(subject) do
    with :ok <- authorize_administer_users(subject) do
      {:ok, list_tenant_users(subject)}
    end
  end

  def update_profile(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    Repo.transaction(fn ->
      user =
        Repo.one(
          from(u in User,
            where:
              u.id == ^user_id and u.tenant_id == ^tenant_id and u.status == :active and
                u.account_type == :human,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      changes =
        case validate_unchanged_profile_email(attrs, user.email) do
          :ok -> Map.take(attrs, [:display_name, "display_name"])
          {:error, reason} -> Repo.rollback(reason)
        end

      updated = user |> User.changeset(changes) |> update_or_rollback()

      insert_audit!(subject, "user.profile_update", "user", user.id, %{
        before: %{display_name: user.display_name},
        after: %{display_name: updated.display_name}
      })

      updated
    end)
    |> transaction_result()
  end

  def change_password(attrs, subject) when is_map(attrs) and is_map(subject) do
    case change_password_with_effects(attrs, subject) do
      {:ok, result} -> {:ok, result.user}
      {:error, _} = error -> error
    end
  end

  def change_password_with_effects(attrs, subject) when is_map(attrs) and is_map(subject) do
    current_password = value(attrs, :current_password)
    new_password = value(attrs, :new_password)

    with :ok <- validate_password(new_password) do
      Repo.transaction(fn ->
        user =
          Repo.one(
            from(u in User,
              where:
                u.id == ^value(subject, :user_id) and
                  u.tenant_id == ^value(subject, :tenant_id) and u.status == :active and
                  u.account_type == :human,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        unless Password.verify(current_password, user.password_hash),
          do: Repo.rollback(:invalid_current_password)

        updated =
          user
          |> User.changeset(%{password_hash: Password.hash(new_password)})
          |> update_or_rollback()

        revoked_session_ids = revoke_other_sessions!(subject)
        insert_audit!(subject, "user.password_change", "user", user.id, %{})
        %{user: updated, revoked_session_ids: revoked_session_ids}
      end)
      |> transaction_result()
    end
  end

  def step_up(attrs, subject) when is_map(attrs) and is_map(subject) do
    password = value(attrs, :current_password)

    Repo.transaction(fn ->
      user =
        Repo.one(
          from(u in User,
            where:
              u.id == ^value(subject, :user_id) and
                u.tenant_id == ^value(subject, :tenant_id) and u.status == :active and
                u.account_type == :human,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      unless Password.verify(password, user.password_hash),
        do: Repo.rollback(:invalid_current_password)

      session =
        Repo.one(
          from(s in Session,
            where:
              s.id == ^value(subject, :session_id) and s.user_id == ^user.id and
                s.tenant_id == ^user.tenant_id and is_nil(s.revoked_at) and
                s.expires_at > ^now() and s.absolute_expires_at > ^now(),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:session_expired)

      stepped_up =
        session
        |> Session.changeset(%{step_up_at: now()})
        |> update_or_rollback()

      insert_audit!(subject, "session.step_up", "session", session.id, %{})
      stepped_up
    end)
    |> transaction_result()
  end

  def list_devices(subject) do
    Device
    |> where(
      [d],
      d.tenant_id == ^value(subject, :tenant_id) and d.user_id == ^value(subject, :user_id)
    )
    |> order_by([d], desc: d.last_seen_at, desc: d.inserted_at)
    |> Repo.all()
  end

  def list_sessions(subject) do
    Session
    |> where(
      [s],
      s.tenant_id == ^value(subject, :tenant_id) and s.user_id == ^value(subject, :user_id)
    )
    |> order_by([s], desc: s.last_used_at)
    |> preload(user: :platform_role_grant)
    |> Repo.all()
  end

  def revoke_device(device_id, subject) do
    Repo.transaction(fn ->
      device =
        Repo.one(
          from(d in Device,
            where:
              d.id == ^device_id and d.tenant_id == ^value(subject, :tenant_id) and
                d.user_id == ^value(subject, :user_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      now = now()
      device |> Device.changeset(%{revoked_at: now}) |> update_or_rollback()

      session_ids =
        Session
        |> where(
          [s],
          s.tenant_id == ^device.tenant_id and s.user_id == ^device.user_id and
            s.device_id == ^device.id and is_nil(s.revoked_at)
        )
        |> select([s], s.id)
        |> Repo.all()

      Session
      |> where(
        [s],
        s.tenant_id == ^device.tenant_id and s.user_id == ^device.user_id and
          s.device_id == ^device.id and is_nil(s.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

      NotificationCommand.device_revoked(
        device.tenant_id,
        device.user_id,
        device.id
      )
      |> NotificationPort.execute()
      |> notification_ok!()

      audio_revocation_ok!(
        AudioCalls.revoke_for_device(device.tenant_id, device.id, "device_revoked")
      )

      insert_audit!(subject, "device.revoke", "device", device.id, %{})
      %{device: device, revoked_session_ids: session_ids}
    end)
    |> transaction_result()
  end

  def revoke_own_session(session_id, subject) do
    revoke_scoped_session(session_id, value(subject, :user_id), subject)
  end

  def list_user_sessions(user_id, subject) do
    with :ok <- authorize_manage_sessions(subject),
         %User{} = actor <- active_actor(subject),
         %User{} = target <-
           Repo.get_by(User,
             id: user_id,
             tenant_id: value(subject, :tenant_id),
             account_type: :human
           ),
         :ok <- authorize_session_target(actor, target) do
      {:ok,
       Session
       |> where([s], s.tenant_id == ^value(subject, :tenant_id) and s.user_id == ^user_id)
       |> order_by([s], desc: s.last_used_at)
       |> preload(user: :platform_role_grant)
       |> Repo.all()}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def admin_revoke_session(user_id, session_id, attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage_sessions(subject),
         {:ok, reason} <- required_reason(attrs) do
      Repo.transaction(fn ->
        actor = active_actor(subject) || Repo.rollback(:forbidden)

        target =
          Repo.one(
            from(u in User,
              where:
                u.id == ^user_id and u.tenant_id == ^value(subject, :tenant_id) and
                  u.account_type == :human,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        case authorize_session_target(actor, target) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        session =
          Repo.one(
            from(s in Session,
              where:
                s.id == ^session_id and s.user_id == ^target.id and
                  s.tenant_id == ^target.tenant_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        revoked =
          session
          |> Session.changeset(%{revoked_at: now()})
          |> update_or_rollback()

        audio_revocation_ok!(
          AudioCalls.revoke_for_sessions(target.tenant_id, [revoked.id], "session_admin_revoked")
        )

        insert_audit!(subject, "session.admin_revoke", "session", session.id, %{
          user_id: target.id,
          reason: reason
        })

        revoked
      end)
      |> transaction_result()
    end
  end

  def change_user(user_id, attrs, subject) when is_map(attrs) and is_map(subject) do
    case change_user_with_effects(user_id, attrs, subject) do
      {:ok, result} -> {:ok, result.user}
      {:error, _} = error -> error
    end
  end

  def change_user_with_effects(user_id, attrs, subject)
      when is_map(attrs) and is_map(subject) do
    with {:ok, command} <- validate_user_lifecycle_change(attrs, subject) do
      Repo.transaction(fn ->
        apply_user_lifecycle_change!(
          user_id,
          command,
          subject,
          :governance_policy_required
        )
      end)
      |> transaction_result()
    end
  end

  @doc false
  def preflight_user_lifecycle_change(user_id, attrs, subject)
      when is_map(attrs) and is_map(subject) do
    cond do
      not valid_uuid?(user_id) ->
        {:error, :not_found}

      not valid_uuid?(value(subject, :tenant_id)) ->
        {:error, :forbidden}

      true ->
        with {:ok, _command} <- validate_user_lifecycle_change(attrs, subject), do: :ok
    end
  end

  def preflight_user_lifecycle_change(_user_id, _attrs, _subject),
    do: {:error, :not_found}

  @doc """
  Applies a governed user-lifecycle change inside a caller-owned transaction.

  The caller supplies only user identifiers excluded from the active-owner
  calculation. IdentityAccess owns authorization, locking, mutation, access
  revocation, audit, and the returned projection.
  """
  @spec apply_user_lifecycle_change(Ecto.UUID.t(), map(), map(), [Ecto.UUID.t()]) ::
          {:ok, %{user: CommsCore.Accounts.UserView.t(), revoked_session_ids: [Ecto.UUID.t()]}}
          | {:error,
             :invalid_owner_exclusions
             | :not_found
             | :transaction_required
             | atom()
             | Ecto.Changeset.t()}
  def apply_user_lifecycle_change(user_id, attrs, subject, excluded_owner_ids)
      when is_map(attrs) and is_map(subject) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not valid_uuid?(user_id) ->
        {:error, :not_found}

      not valid_owner_exclusions?(excluded_owner_ids) ->
        {:error, :invalid_owner_exclusions}

      true ->
        with {:ok, command} <- validate_user_lifecycle_change(attrs, subject) do
          result =
            apply_user_lifecycle_change!(
              user_id,
              command,
              subject,
              Enum.uniq(excluded_owner_ids)
            )

          {:ok,
           %{result | user: CommsCore.Accounts.Projector.user(result.user, platform_access: true)}}
        end
    end
  end

  def apply_user_lifecycle_change(_user_id, _attrs, _subject, _excluded_owner_ids),
    do: {:error, :invalid_owner_exclusions}

  def get_user_for_subject(subject) do
    Repo.get_by(User,
      id: value(subject, :user_id),
      tenant_id: value(subject, :tenant_id),
      status: :active
    )
  end

  @doc """
  Grants or revokes a time-bounded platform role from an authenticated
  release/console workflow.

  This function is intentionally separate from tenant administration changesets and
  HTTP controllers. It fails closed unless a strong management secret is configured,
  the caller supplies that secret using `:grant_token`, and explicit `:actor` and
  `:reason` evidence is provided. Grants also require `:ttl_seconds` between five
  minutes and eight hours. The grant update and audit event commit atomically.
  Passing `nil`, `"none"`, or `"revoke"` revokes the current platform role and
  ignores `:ttl_seconds`.
  """
  def set_platform_role_from_console(user_id, role, attrs)
      when is_binary(user_id) and is_map(attrs) do
    with {:ok, configured_secret} <- platform_role_management_secret(),
         :ok <-
           verify_platform_role_management_secret(configured_secret, value(attrs, :grant_token)),
         {:ok, platform_role} <- normalize_platform_role(role),
         {:ok, ttl_seconds} <- platform_role_ttl(platform_role, value(attrs, :ttl_seconds)),
         {:ok, actor} <- required_platform_audit_text(attrs, :actor, 3, 120),
         {:ok, reason} <- required_platform_audit_text(attrs, :reason, 8, 500) do
      Repo.transaction(fn ->
        user =
          Repo.one(
            from(u in User,
              where: u.id == ^user_id,
              lock: "FOR UPDATE"
            )
          ) ||
            Repo.rollback(:not_found)

        authorize_platform_role_target!(user, platform_role)

        previous_grant =
          Repo.one(
            from(g in PlatformRoleGrant,
              where: g.user_id == ^user.id and g.tenant_id == ^user.tenant_id,
              lock: "FOR UPDATE"
            )
          )

        expires_at =
          if platform_role,
            do: DateTime.add(now(), ttl_seconds, :second),
            else: nil

        current_grant =
          replace_platform_role_grant!(user, previous_grant, platform_role, expires_at)

        updated =
          user
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()
          |> with_platform_access(platform_role, expires_at)

        action = if is_nil(platform_role), do: "platform_role.revoke", else: "platform_role.grant"

        Audit.record(%{
          tenant_id: user.tenant_id,
          actor_user_id: nil,
          action: action,
          resource_type: "user",
          resource_id: user.id,
          metadata: %{
            actor: actor,
            reason: reason,
            source: "release_console",
            before_grant_id: previous_grant && previous_grant.id,
            before: previous_grant && previous_grant.role,
            before_expires_at: previous_grant && previous_grant.expires_at,
            after_grant_id: current_grant && current_grant.id,
            after: platform_role,
            after_expires_at: expires_at,
            ttl_seconds: ttl_seconds
          }
        })
        |> audit_or_rollback()

        updated
      end)
      |> transaction_result()
    end
  end

  def set_platform_role_from_console(_user_id, _role, _attrs),
    do: {:error, :invalid_platform_role_request}

  def subject_for_session(%Session{} = session, request_id \\ nil) do
    session = Repo.preload(session, [user: :platform_role_grant], force: true)
    platform_access = PlatformAccess.for_subject(session.user)

    Map.merge(
      %{
        tenant_id: session.tenant_id,
        user_id: session.user_id,
        device_id: session.device_id,
        session_id: session.id,
        request_id: request_id,
        role: session.user.role,
        step_up_at: session.step_up_at
      },
      platform_access
    )
  end

  defp upsert_device(user, attrs) do
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

  defp create_session(user, device) do
    id = Ecto.UUID.generate()
    {token, hash} = refresh_token(id)
    created_at = now()
    deadlines = new_session_deadlines(created_at)

    changeset =
      Session.changeset(%Session{id: id}, %{
        tenant_id: user.tenant_id,
        user_id: user.id,
        device_id: device.id,
        refresh_token_hash: hash,
        expires_at: deadlines.expires_at,
        absolute_expires_at: deadlines.absolute_expires_at,
        last_used_at: created_at
      })

    case Repo.insert(changeset) do
      {:ok, session} -> {:ok, session, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rotate_refresh_session(%Session{} = session, secret) do
    with true <- active_session?(session),
         true <- secure_hash_equals(session.refresh_token_hash, secret),
         %User{status: :active, account_type: :human} = user <-
           Repo.get_by(User, id: session.user_id, tenant_id: session.tenant_id),
         %Device{} = device <-
           Repo.get_by(Device,
             id: session.device_id,
             tenant_id: session.tenant_id,
             user_id: session.user_id
           ),
         true <- is_nil(device.revoked_at),
         %Tenant{status: :active} = tenant <- Repo.get(Tenant, session.tenant_id) do
      {new_token, new_hash} = refresh_token(session.id)

      case session
           |> Session.changeset(%{
             refresh_token_hash: new_hash,
             last_used_at: now(),
             expires_at: rotated_session_expires_at(session.absolute_expires_at)
           })
           |> Repo.update() do
        {:ok, updated} ->
          {:ok,
           %{
             tenant: tenant,
             user: user,
             device: device,
             session: updated,
             refresh_token: new_token
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  defp rotate_refresh_session(nil, _secret), do: {:error, :invalid_refresh_token}

  defp refresh_token(session_id) do
    secret = :crypto.strong_rand_bytes(@session_bytes)
    encoded = Base.url_encode64(secret, padding: false)
    {"#{session_id}.#{encoded}", :crypto.hash(:sha256, secret)}
  end

  defp parse_refresh_token(token) do
    case String.split(token, ".", parts: 2) do
      [session_id, secret_text] ->
        with {:ok, secret} <- Base.url_decode64(secret_text, padding: false),
             {:ok, _} <- Ecto.UUID.cast(session_id) do
          {:ok, session_id, secret}
        else
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp parse_socket_ticket(ticket) do
    case String.split(ticket, ".", parts: 2) do
      [id, encoded] ->
        with {:ok, _uuid} <- Ecto.UUID.cast(id),
             {:ok, secret} <- Base.url_decode64(encoded, padding: false),
             true <- byte_size(secret) == @session_bytes do
          {:ok, id, secret}
        else
          _ -> {:error, :invalid_socket_ticket}
        end

      _ ->
        {:error, :invalid_socket_ticket}
    end
  end

  defp prune_socket_tickets! do
    retention = Application.get_env(:comms_core, :socket_ticket_retention_seconds, 3_600)
    cutoff = DateTime.add(now(), -max(retention, 0), :second)

    stale_ids =
      from(t in SocketTicket,
        where: t.expires_at < ^cutoff or (not is_nil(t.consumed_at) and t.consumed_at < ^cutoff),
        order_by: [asc: t.expires_at],
        limit: 500,
        select: t.id
      )

    Repo.delete_all(from(t in SocketTicket, where: t.id in subquery(stale_ids)))
    :ok
  end

  defp secure_hash_equals(hash, secret) when is_binary(hash) and is_binary(secret) do
    actual = :crypto.hash(:sha256, secret)
    byte_size(actual) == byte_size(hash) and :crypto.hash_equals(actual, hash)
  end

  defp secure_hash_equals(_, _), do: false

  defp active_session?(session) do
    current_time = now()

    is_nil(session.revoked_at) and DateTime.compare(session.expires_at, current_time) == :gt and
      DateTime.compare(session.absolute_expires_at, current_time) == :gt
  end

  defp new_session_deadlines(created_at) do
    absolute_expires_at =
      DateTime.add(created_at, session_absolute_ttl_seconds(), :second)

    %{
      absolute_expires_at: absolute_expires_at,
      expires_at:
        earlier_deadline(
          DateTime.add(created_at, session_ttl_seconds(), :second),
          absolute_expires_at
        )
    }
  end

  defp rotated_session_expires_at(absolute_expires_at),
    do: earlier_deadline(DateTime.add(now(), session_ttl_seconds(), :second), absolute_expires_at)

  defp earlier_deadline(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp session_ttl_seconds,
    do: Application.get_env(:comms_core, :session_ttl_seconds, 2_592_000) |> max(0)

  defp session_absolute_ttl_seconds,
    do: Application.get_env(:comms_core, :session_absolute_ttl_seconds, 2_592_000) |> max(0)

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp create_one_time_bootstrap(attrs, identity, password_hash) do
    now = now()
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()

    tenant =
      Administration.create_bootstrap_tenant(%{
        id: tenant_id,
        name: value(attrs, :tenant_name),
        slug: identity.tenant_slug
      })
      |> owner_result_or_rollback()

    user =
      insert_or_rollback(
        User.changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: "local:#{identity.owner_email}",
          display_name: value(attrs, :display_name),
          email: identity.owner_email,
          password_hash: password_hash,
          account_type: :human,
          role: :owner,
          status: :active
        })
      )

    conversation =
      ConversationBootstrapPort.create_initial_channel(%InitialConversationCommand{
        id: conversation_id,
        tenant_id: tenant_id,
        owner_user_id: user_id,
        joined_at: now
      })
      |> owner_result_or_rollback()

    _audit =
      Audit.record(%{
        tenant_id: tenant_id,
        actor_user_id: user_id,
        action: "tenant.bootstrap",
        resource_type: "tenant",
        resource_id: tenant_id,
        metadata: %{initial_conversation_id: conversation_id, source: "release"}
      })
      |> audit_or_rollback()

    user = maybe_apply_bootstrap_platform_role!(user)

    %{status: :created, tenant: tenant, user: user, conversation: conversation}
  end

  defp existing_bootstrap(tenant, identity) do
    owner =
      Repo.one(
        from(u in User,
          where:
            u.tenant_id == ^tenant.id and u.role == :owner and u.status == :active and
              fragment("lower(?)", u.email) == ^identity.owner_email,
          limit: 1,
          lock: "FOR UPDATE"
        )
      )

    case owner do
      %User{} = user ->
        case ConversationBootstrapPort.fetch_initial_channel(tenant.id, user.id) do
          {:ok, conversation} when not is_nil(conversation) ->
            user = maybe_apply_bootstrap_platform_role!(user)
            %{status: :existing, tenant: tenant, user: user, conversation: conversation}

          {:ok, nil} ->
            Repo.rollback(:bootstrap_identity_conflict)

          {:error, reason} ->
            Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:bootstrap_identity_conflict)
    end
  end

  defp bootstrap_identity(attrs) do
    tenant_slug =
      attrs
      |> value(:tenant_slug)
      |> to_string()
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    owner_email =
      attrs
      |> value(:email)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    %{tenant_slug: tenant_slug, owner_email: owner_email}
  end

  defp maybe_apply_bootstrap_platform_role!(%User{} = user) do
    if Application.get_env(:comms_core, :allow_bootstrap_platform_role, false) do
      with {:ok, role} when not is_nil(role) <-
             normalize_platform_role(Application.get_env(:comms_core, :bootstrap_platform_role)),
           {:ok, ttl_seconds} <-
             platform_role_ttl(
               role,
               Application.get_env(
                 :comms_core,
                 :bootstrap_platform_role_ttl_seconds,
                 @platform_role_max_ttl_seconds
               )
             ) do
        case platform_role_grant(user.id, user.tenant_id) do
          %PlatformRoleGrant{role: ^role} = grant ->
            if DateTime.compare(grant.expires_at, now()) == :gt,
              do: with_platform_access(user, grant.role, grant.expires_at),
              else: renew_bootstrap_platform_role!(user, grant, role, ttl_seconds)

          previous_grant ->
            renew_bootstrap_platform_role!(user, previous_grant, role, ttl_seconds)
        end
      else
        _ -> Repo.rollback(:invalid_bootstrap_platform_role)
      end
    else
      user
    end
  end

  defp renew_bootstrap_platform_role!(user, previous_grant, role, ttl_seconds) do
    expires_at = DateTime.add(now(), ttl_seconds, :second)
    current_grant = replace_platform_role_grant!(user, previous_grant, role, expires_at)

    Audit.record(%{
      tenant_id: user.tenant_id,
      actor_user_id: nil,
      action: "platform_role.bootstrap_grant",
      resource_type: "user",
      resource_id: user.id,
      metadata: %{
        actor: "release_bootstrap",
        reason: "explicit local-proof bootstrap configuration",
        source: "local_proof",
        before_grant_id: previous_grant && previous_grant.id,
        before: previous_grant && previous_grant.role,
        before_expires_at: previous_grant && previous_grant.expires_at,
        after_grant_id: current_grant.id,
        after: role,
        after_expires_at: expires_at,
        ttl_seconds: ttl_seconds
      }
    })
    |> audit_or_rollback()

    with_platform_access(user, role, expires_at)
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp revoke_scoped_session(session_id, user_id, subject, action \\ "session.revoke") do
    Repo.transaction(fn ->
      session =
        Repo.one(
          from(s in Session,
            where:
              s.id == ^session_id and s.user_id == ^user_id and
                s.tenant_id == ^value(subject, :tenant_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      now = now()
      session |> Session.changeset(%{revoked_at: now}) |> update_or_rollback()

      audio_revocation_ok!(
        AudioCalls.revoke_for_sessions(session.tenant_id, [session.id], "session_revoked")
      )

      insert_audit!(subject, action, "session", session.id, %{user_id: user_id})
      session
    end)
    |> transaction_result()
  end

  defp revoke_other_sessions!(subject) do
    query =
      Session
      |> where(
        [s],
        s.tenant_id == ^value(subject, :tenant_id) and s.user_id == ^value(subject, :user_id) and
          s.id != ^value(subject, :session_id) and is_nil(s.revoked_at)
      )

    ids = query |> select([s], s.id) |> Repo.all()
    Repo.update_all(query, set: [revoked_at: now(), updated_at: now()])

    audio_revocation_ok!(
      AudioCalls.revoke_for_sessions(value(subject, :tenant_id), ids, "password_changed")
    )

    ids
  end

  defp revoke_user_access!(user) do
    timestamp = now()

    session_query =
      Session
      |> where(
        [s],
        s.tenant_id == ^user.tenant_id and s.user_id == ^user.id and is_nil(s.revoked_at)
      )

    session_ids = session_query |> select([s], s.id) |> Repo.all()

    Repo.update_all(session_query, set: [revoked_at: timestamp, updated_at: timestamp])

    Device
    |> where(
      [d],
      d.tenant_id == ^user.tenant_id and d.user_id == ^user.id and is_nil(d.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: timestamp, updated_at: timestamp])

    NotificationCommand.user_access_revoked(
      user.tenant_id,
      user.id,
      "user_lifecycle_revoked"
    )
    |> NotificationPort.execute()
    |> notification_ok!()

    audio_revocation_ok!(
      AudioCalls.revoke_for_user(user.tenant_id, user.id, "user_lifecycle_revoked")
    )

    session_ids
  end

  defp audio_revocation_ok!({:ok, _count}), do: :ok
  defp audio_revocation_ok!({:error, reason}), do: Repo.rollback(reason)

  defp notification_ok!(:ok), do: :ok
  defp notification_ok!({:error, reason}), do: Repo.rollback(reason)
  defp notification_ok!(_unexpected), do: Repo.rollback(:notification_delivery_unavailable)

  defp erase_user_for_governance(
         tenant_id,
         user_id,
         pending_deletion_user_ids,
         timestamp
       ) do
    lock_tenant_users!(tenant_id)

    with %User{} = user <-
           Repo.one(
             from(u in User,
               where: u.id == ^user_id and u.tenant_id == ^tenant_id,
               lock: "FOR UPDATE"
             )
           ),
         :ok <- ensure_governance_erasure_owner_safe(user, pending_deletion_user_ids),
         {:ok, _anonymized_user} <- anonymize_user_for_governance(user),
         revoked_session_ids <- revoke_user_access_for_governance(user, timestamp) do
      {:ok, %{user_id: user.id, revoked_session_ids: revoked_session_ids}}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_governance_erasure_owner_safe(
         %User{role: :owner, status: :active} = user,
         pending_deletion_user_ids
       ) do
    remaining =
      User
      |> where(
        [candidate],
        candidate.tenant_id == ^user.tenant_id and candidate.id != ^user.id and
          candidate.role == :owner and candidate.status == :active and
          candidate.id not in ^pending_deletion_user_ids
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: {:error, :last_owner_required}, else: :ok
  end

  defp ensure_governance_erasure_owner_safe(_user, _pending_deletion_user_ids), do: :ok

  defp anonymize_user_for_governance(user) do
    anonymized = "deleted-#{user.id}"

    user
    |> User.changeset(%{
      external_subject: anonymized,
      display_name: "Deleted user",
      email: "#{anonymized}@invalid.example",
      status: :deleted
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp revoke_user_access_for_governance(user, timestamp) do
    session_query =
      from(s in Session,
        where: s.tenant_id == ^user.tenant_id and s.user_id == ^user.id and is_nil(s.revoked_at)
      )

    revoked_session_ids = session_query |> select([s], s.id) |> Repo.all()
    Repo.update_all(session_query, set: [revoked_at: timestamp, updated_at: timestamp])

    Device
    |> where(
      [d],
      d.tenant_id == ^user.tenant_id and d.user_id == ^user.id and is_nil(d.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: timestamp, updated_at: timestamp])

    revoked_session_ids
  end

  defp valid_governance_erasure_command?(
         tenant_id,
         user_id,
         pending_deletion_user_ids,
         timestamp
       ) do
    valid_uuid?(tenant_id) and valid_uuid?(user_id) and is_list(pending_deletion_user_ids) and
      Enum.all?(pending_deletion_user_ids, &valid_uuid?/1) and match?(%DateTime{}, timestamp)
  end

  defp validate_user_lifecycle_change(attrs, subject) do
    tenant_id = value(subject, :tenant_id)

    if valid_uuid?(tenant_id) do
      with :ok <- reject_platform_role_attribute(attrs),
           :ok <- reject_service_account_attribute(attrs),
           :ok <- authorize_manage_user_lifecycle(subject),
           {:ok, reason} <- required_reason(attrs),
           {:ok, expected_version} <- expected_version(attrs),
           {:ok, role} <- optional_role(attrs),
           {:ok, status} <- optional_status(attrs) do
        {:ok,
         %{
           tenant_id: tenant_id,
           reason: reason,
           expected_version: expected_version,
           role: role,
           status: status,
           display_name: value(attrs, :display_name)
         }}
      end
    else
      {:error, :forbidden}
    end
  end

  defp apply_user_lifecycle_change!(user_id, command, subject, excluded_owner_ids) do
    tenant_id = command.tenant_id

    policy = AdmissionQuotas.locked_policy(tenant_id) |> admission_policy_or_rollback()
    lock_tenant_users!(tenant_id)

    target =
      Repo.one(
        from(u in User,
          where:
            u.id == ^user_id and u.tenant_id == ^tenant_id and u.status != :deleted and
              u.account_type == :human,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    if target.lock_version != command.expected_version, do: Repo.rollback(:stale_version)

    actor =
      Repo.get_by!(User,
        id: value(subject, :user_id),
        tenant_id: tenant_id,
        status: :active,
        account_type: :human
      )

    authorize_user_change!(actor, target, command.role, command.status)
    ensure_last_owner!(target, command.role, command.status, excluded_owner_ids)

    if target.status != :active and command.status == :active do
      quota_ok!(ensure_active_user_capacity(tenant_id, policy))
    end

    changes =
      %{}
      |> maybe_put(:role, command.role)
      |> maybe_put(:status, command.status)
      |> maybe_put(:display_name, command.display_name)

    updated =
      target
      |> User.changeset(changes)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    revoked_session_ids =
      if updated.status != :active, do: revoke_user_access!(updated), else: []

    insert_audit!(subject, "user.lifecycle_update", "user", target.id, %{
      reason: command.reason,
      before: %{role: target.role, status: target.status, display_name: target.display_name},
      after: %{role: updated.role, status: updated.status, display_name: updated.display_name}
    })

    %{user: updated, revoked_session_ids: revoked_session_ids}
  end

  defp valid_owner_exclusions?(values) when is_list(values),
    do: Enum.all?(values, &valid_uuid?/1)

  defp valid_owner_exclusions?(_values), do: false

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp lock_tenant_users!(tenant_id) do
    Repo.all(
      from(u in User,
        where: u.tenant_id == ^tenant_id,
        order_by: [asc: u.id],
        select: u.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_last_owner!(
         %User{role: :owner, status: :active},
         role,
         status,
         :governance_policy_required
       )
       when role not in [nil, :owner] or status not in [nil, :active],
       do: Repo.rollback(:governance_policy_required)

  defp ensure_last_owner!(
         %User{role: :owner, status: :active} = target,
         role,
         status,
         excluded_owner_ids
       )
       when (role not in [nil, :owner] or status not in [nil, :active]) and
              is_list(excluded_owner_ids) do
    remaining =
      User
      |> where(
        [u],
        u.tenant_id == ^target.tenant_id and u.id != ^target.id and u.role == :owner and
          u.status == :active and u.id not in ^excluded_owner_ids
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: Repo.rollback(:last_owner_required)
  end

  defp ensure_last_owner!(_, _, _, _), do: :ok

  defp authorize_user_change!(%User{role: :owner}, _target, _role, _status), do: :ok

  defp authorize_user_change!(%User{role: :admin}, %User{role: target_role}, role, _status) do
    elevated = [:owner, :admin, :compliance_admin, :security_admin]

    if target_role in elevated or role in elevated,
      do: Repo.rollback(:forbidden),
      else: :ok
  end

  defp authorize_user_change!(_, _, _, _), do: Repo.rollback(:forbidden)

  defp authorize_role_assignment(subject, role)
       when role in [:member, :moderator, :admin, :compliance_admin, :security_admin] do
    case Repo.get_by(User,
           id: value(subject, :user_id),
           tenant_id: value(subject, :tenant_id),
           status: :active
         ) do
      %User{role: :owner} -> :ok
      %User{role: :admin} when role in [:member, :moderator] -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_role_assignment(_, _), do: {:error, :invalid_role}

  defp optional_role(attrs) do
    case value(attrs, :role) do
      nil ->
        {:ok, nil}

      role ->
        if normalized = normalize_role(role, nil),
          do: {:ok, normalized},
          else: {:error, :invalid_role}
    end
  end

  defp optional_status(attrs) do
    case value(attrs, :status) do
      nil ->
        {:ok, nil}

      status ->
        if normalized = normalize_enum(status, [:active, :suspended, :deleted]),
          do: {:ok, normalized},
          else: {:error, :invalid_status}
    end
  end

  defp expected_version(attrs) do
    case value(attrs, :version) || value(attrs, :lock_version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  defp normalize_role(role, default),
    do:
      normalize_enum(role, [
        :member,
        :moderator,
        :admin,
        :compliance_admin,
        :security_admin,
        :owner
      ]) || default

  defp requested_role(attrs) do
    case value(attrs, :role) do
      nil ->
        {:ok, :member}

      role ->
        case normalize_role(role, nil) do
          nil -> {:error, :invalid_role}
          normalized -> {:ok, normalized}
        end
    end
  end

  defp normalize_enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp normalize_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum(_, _), do: nil

  defp reject_platform_role_attribute(attrs) do
    if Map.has_key?(attrs, :platform_role) or Map.has_key?(attrs, "platform_role") or
         Map.has_key?(attrs, :platform_role_expires_at) or
         Map.has_key?(attrs, "platform_role_expires_at"),
       do: {:error, :platform_role_console_only},
       else: :ok
  end

  defp normalize_platform_role(role) when role in [nil, "", "none", "revoke"], do: {:ok, nil}

  defp normalize_platform_role(role) do
    case normalize_enum(role, @platform_roles) do
      nil -> {:error, :invalid_platform_role}
      normalized -> {:ok, normalized}
    end
  end

  defp platform_role_ttl(nil, _value), do: {:ok, nil}

  defp platform_role_ttl(_role, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {ttl, ""} -> platform_role_ttl(:grant, ttl)
      _ -> {:error, :invalid_platform_role_ttl}
    end
  end

  defp platform_role_ttl(_role, value)
       when is_integer(value) and
              value >= @platform_role_min_ttl_seconds and
              value <= @platform_role_max_ttl_seconds,
       do: {:ok, value}

  defp platform_role_ttl(_role, _value), do: {:error, :invalid_platform_role_ttl}

  defp platform_role_grant(user_id, tenant_id) do
    Repo.get_by(PlatformRoleGrant, user_id: user_id, tenant_id: tenant_id)
  end

  defp authorize_platform_role_target!(_user, nil), do: :ok

  defp authorize_platform_role_target!(%User{status: :active, account_type: :human}, _role),
    do: :ok

  defp authorize_platform_role_target!(_user, _role), do: Repo.rollback(:not_found)

  defp replace_platform_role_grant!(_user, nil, nil, nil), do: nil

  defp replace_platform_role_grant!(_user, %PlatformRoleGrant{} = grant, nil, nil) do
    case Repo.delete(grant) do
      {:ok, _grant} -> nil
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp replace_platform_role_grant!(user, previous_grant, role, expires_at) do
    if previous_grant do
      case Repo.delete(previous_grant) do
        {:ok, _grant} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    grant_id = Ecto.UUID.generate()

    %PlatformRoleGrant{id: grant_id}
    |> PlatformRoleGrant.changeset(%{
      id: grant_id,
      tenant_id: user.tenant_id,
      user_id: user.id,
      role: role,
      expires_at: expires_at
    })
    |> insert_or_rollback()
  end

  defp with_platform_access(%User{} = user, role, expires_at) do
    %{user | platform_role: role, platform_role_expires_at: expires_at}
  end

  defp platform_role_management_secret do
    case Application.get_env(:comms_core, :platform_role_management_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _ -> {:error, :platform_role_management_unavailable}
    end
  end

  defp verify_platform_role_management_secret(configured_secret, provided_secret) do
    provided_secret = if is_binary(provided_secret), do: provided_secret, else: ""

    configured_digest = :crypto.hash(:sha256, configured_secret)
    provided_digest = :crypto.hash(:sha256, provided_secret)

    if :crypto.hash_equals(configured_digest, provided_digest),
      do: :ok,
      else: {:error, :invalid_platform_role_management_secret}
  end

  defp required_platform_audit_text(attrs, key, min_length, max_length) do
    case value(attrs, key) do
      text when is_binary(text) ->
        normalized = String.trim(text)

        if String.length(normalized) in min_length..max_length,
          do: {:ok, normalized},
          else: {:error, :platform_role_audit_context_required}

      _ ->
        {:error, :platform_role_audit_context_required}
    end
  end

  defp required_reason(attrs) do
    case value(attrs, :reason) do
      reason when is_binary(reason) ->
        normalized = String.trim(reason)

        if String.length(normalized) in 3..1_000,
          do: {:ok, normalized},
          else: {:error, :reason_required}

      _ ->
        {:error, :reason_required}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp active_actor(subject) do
    Repo.get_by(User,
      id: value(subject, :user_id),
      tenant_id: value(subject, :tenant_id),
      status: :active,
      account_type: :human
    )
  end

  defp reject_service_account_attribute(attrs) do
    if value(attrs, :account_type) in [nil, :human, "human"],
      do: :ok,
      else: {:error, :forbidden}
  end

  defp reject_service_identity_email(tenant_id, email) do
    service_identity? =
      Repo.exists?(
        from(user in User,
          where:
            user.tenant_id == ^tenant_id and user.account_type == :service and
              fragment("lower(?)", user.email) == ^String.downcase(email)
        )
      )

    if service_identity?, do: {:error, :forbidden}, else: :ok
  end

  defp reject_existing_human_identity(tenant_id, email) do
    existing_identity? =
      Repo.exists?(
        from(user in User,
          where:
            user.tenant_id == ^tenant_id and user.account_type == :human and
              fragment("lower(?)", user.email) == ^String.downcase(email)
        )
      )

    if existing_identity?, do: {:error, :invitation_identity_conflict}, else: :ok
  end

  defp validate_unchanged_profile_email(attrs, current_email) do
    supplied_emails =
      [:email, "email"]
      |> Enum.filter(&Map.has_key?(attrs, &1))
      |> Enum.map(&Map.fetch!(attrs, &1))

    unchanged? =
      Enum.all?(supplied_emails, fn
        email when is_binary(email) -> normalize_email(email) == normalize_email(current_email)
        _ -> false
      end)

    if unchanged?, do: :ok, else: {:error, :email_change_requires_verification}
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(_email), do: ""

  defp authorize_session_target(%User{role: :owner}, _target), do: :ok

  defp authorize_session_target(
         %User{role: :security_admin},
         %User{role: role}
       )
       when role not in [:owner, :security_admin],
       do: :ok

  defp authorize_session_target(_, _), do: {:error, :forbidden}

  defp audit_command(subject, action, resource_type, resource_id, metadata) do
    %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    }
  end

  defp insert_audit!(subject, action, resource_type, resource_id, metadata) do
    subject
    |> audit_command(action, resource_type, resource_id, metadata)
    |> Audit.record()
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp owner_result_or_rollback({:ok, value}), do: value
  defp owner_result_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp admission_policy_or_rollback({:ok, %AdmissionPolicy{} = policy}), do: policy
  defp admission_policy_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

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

  defp platform_deadline_matches?(_, _), do: false

  defp authorize_tenant_role_with_step_up(action, subject, allowed_roles) do
    case access_grant(subject) do
      {:ok, %AccessGrant{} = grant} ->
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
