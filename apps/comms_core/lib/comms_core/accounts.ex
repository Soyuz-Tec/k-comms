defmodule CommsCore.Accounts do
  @behaviour CommsCore.Administration.AuthorizationActorPort
  @behaviour CommsCore.Administration.IdentityAccessPort
  @behaviour CommsCore.Administration.InvitationIdentityPort

  alias CommsCore.Accounts.{
    AccessControl,
    AccessGrant,
    Bootstrap,
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    ConversationBootstrapPort,
    Directory,
    GovernanceErasure,
    GuestIdentities,
    Invitations,
    NotificationCommand,
    NotificationRecipient,
    NotificationPort,
    PlatformGrants,
    ReleaseInventory,
    Session,
    Sessions,
    UserLifecycle
  }

  alias CommsCore.Audit.Actor

  alias CommsCore.Administration.{
    AdmissionPolicy,
    InvitationIdentityAuthorization,
    InvitedUserCommand
  }

  alias CommsCore.{
    Administration,
    Repo,
    ValidationError
  }

  @doc false
  def release_tenant_fingerprint_fragment(repo, tenant_id)
      when is_atom(repo) and is_binary(tenant_id) do
    ReleaseInventory.tenant_fingerprint_fragment(repo, tenant_id)
  end

  @doc """
  Resolves an active human or guest session into persistence-free
  authorization facts.

  The tenant, user, device, and session identifiers must describe the same
  active identity. A platform grant is returned as verified only when the
  subject carries the exact current grant id, role, and expiry.
  """
  @spec access_grant(map()) :: {:ok, AccessGrant.t()} | {:error, :forbidden}
  def access_grant(subject), do: AccessControl.access_grant(subject)

  @doc """
  Locks the active session before resolving the Ecto-free Calls access grant.

  The caller must already own a transaction and must acquire the tenant and
  conversation locks first. The shared session lock serializes credential
  issuance with session revocation while the normal access-grant query
  revalidates the active human or unexpired guest user and unrevoked device.
  """
  @spec lock_access_grant(map()) ::
          {:ok, AccessGrant.t()} | {:error, :forbidden | :transaction_required}
  def lock_access_grant(subject), do: AccessControl.lock_access_grant(subject)

  @impl CommsCore.Administration.IdentityAccessPort
  def resolve_access(subject), do: AccessControl.resolve_access(subject)

  @impl CommsCore.Administration.AuthorizationActorPort
  def resolve_authorization_actor(subject), do: AccessControl.resolve_authorization_actor(subject)

  @doc """
  Counts active IdentityAccess users for the tenant without exposing User
  persistence.
  """
  @spec active_user_count(Ecto.UUID.t()) :: non_neg_integer()
  def active_user_count(tenant_id), do: Directory.active_user_count(tenant_id)

  @doc """
  Counts every persisted guest identity for release rollback safety.

  This intentionally includes expired, revoked, suspended, and deleted guest
  rows. Code predating guest identities cannot safely decode any of them, so
  the release boundary must not treat lifecycle state as evidence that a row is
  rollback-compatible.
  """
  @spec persisted_guest_identity_count() :: non_neg_integer()
  def persisted_guest_identity_count, do: Directory.persisted_guest_identity_count()

  @doc """
  Counts persisted conversation-only human identities for rollback safety.

  Suspended and deleted rows are included because a legacy release would treat
  every such human as workspace-scoped after the access-scope column is gone.
  """
  @spec persisted_conversation_only_human_count() :: non_neg_integer()
  def persisted_conversation_only_human_count,
    do: Directory.persisted_conversation_only_human_count()

  @doc """
  Resolves requested user IDs that are active in the exact tenant.

  Human and service identities are both eligible. Results are de-duplicated by
  persistence and returned in user-id order.
  """
  @spec resolve_active_user_ids(String.t(), [String.t()]) :: [String.t()]
  def resolve_active_user_ids(tenant_id, user_ids),
    do: Directory.resolve_active_user_ids(tenant_id, user_ids)

  @doc """
  Resolves requested tenant users into stable identity projections.

  Existing permanent identities are returned regardless of lifecycle status so
  owner contexts can display suspended or erased members without receiving User
  persistence. Expired guest identities fail closed even if asynchronous
  membership cleanup has not completed. Results are ordered by display name and
  then user ID.
  """
  @spec resolve_user_views(String.t(), [String.t()]) :: [CommsCore.Accounts.UserView.t()]
  def resolve_user_views(tenant_id, user_ids),
    do: Directory.resolve_user_views(tenant_id, user_ids)

  @doc """
  Resolves display labels for identities referenced by retained content.

  The caller must derive IDs from an already authorized, tenant-scoped page.
  Unlike active member projections, this deliberately includes expired guests
  and other retained lifecycle states so durable messages remain attributable.
  Erased identities always render as `Deleted user`.

  Input is fail-closed, de-duplicated, and bounded to one message page. Results
  contain only user ID and display name and are ordered by user ID.
  """
  @spec resolve_retained_sender_labels(String.t(), [String.t()]) ::
          [CommsCore.Accounts.RetainedSenderLabelView.t()]
  def resolve_retained_sender_labels(tenant_id, user_ids),
    do: Directory.resolve_retained_sender_labels(tenant_id, user_ids)

  @doc """
  Lists active human identities visible to the authenticated caller.

  The result is tenant-scoped, excludes the caller, carries no email or role
  data, and uses an opaque keyset cursor ordered by normalized display name and
  user id.
  """
  @spec list_directory_views(map(), map()) ::
          {:ok,
           %{
             people: [CommsCore.Accounts.DirectoryPersonView.t()],
             next_cursor: String.t() | nil
           }}
          | {:error, :forbidden | :invalid_cursor | :invalid_search_query}
  def list_directory_views(params, subject) when is_map(params) and is_map(subject) do
    with {:ok, %AccessGrant{access_scope: :workspace} = grant} <- access_grant(subject) do
      Directory.list_directory_views(params, grant)
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :forbidden}
    end
  end

  def list_directory_views(_params, _subject), do: {:error, :forbidden}

  @doc false
  @spec lock_active_human_directory_users(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, [CommsCore.Accounts.DirectoryPersonView.t()]}
          | {:error, :not_found | :transaction_required}
  def lock_active_human_directory_users(tenant_id, user_ids),
    do: Directory.lock_active_human_directory_users(tenant_id, user_ids)

  @doc """
  Verifies that a governance target exists in the exact tenant.
  """
  @spec validate_governance_user(String.t(), String.t()) :: :ok | {:error, :not_found}
  def validate_governance_user(tenant_id, user_id),
    do: Directory.validate_governance_user(tenant_id, user_id)

  @doc """
  Verifies that a moderation assignee is active and carries an eligible tenant
  role in the exact tenant.
  """
  @spec validate_moderation_assignee(String.t(), String.t()) ::
          :ok | {:error, :invalid_assignee}
  def validate_moderation_assignee(tenant_id, user_id),
    do: Directory.validate_moderation_assignee(tenant_id, user_id)

  @doc """
  Returns the earliest-created active owner ID used for retention work.
  """
  @spec retention_actor_id(String.t()) ::
          {:ok, String.t()} | {:error, :last_owner_required}
  def retention_actor_id(tenant_id), do: Directory.retention_actor_id(tenant_id)

  @doc """
  Locks IdentityAccess users and verifies that a governed erasure can preserve
  an active owner after excluding approved or in-progress user deletions.

  The caller must already own the transaction that will perform the governed
  transition.
  """
  @spec ensure_governance_erasure_allowed(String.t(), String.t(), [String.t()]) ::
          :ok
          | {:error,
             :invalid_owner_exclusions
             | :last_owner_required
             | :not_found
             | :transaction_required}
  def ensure_governance_erasure_allowed(tenant_id, user_id, excluded_user_ids) do
    GovernanceErasure.ensure_allowed(tenant_id, user_id, excluded_user_ids)
  end

  @doc """
  Resolves active workspace humans into the minimal projection needed for
  notification delivery. Conversation-only humans are deliberately excluded
  because their self-asserted email identifiers have not been verified.

  Results are scoped to the exact tenant, de-duplicated by persistence, and
  returned in user-id order.
  """
  @spec resolve_notification_recipients(String.t(), [String.t()]) ::
          [NotificationRecipient.t()]
  def resolve_notification_recipients(tenant_id, user_ids),
    do: Directory.resolve_notification_recipients(tenant_id, user_ids)

  @doc """
  Returns the requested device ids that remain eligible for push delivery.

  Eligibility is owned by IdentityAccess: the user must be an active human and
  each device must belong to that same tenant and user and remain unrevoked.
  """
  @spec notification_eligible_device_ids(String.t(), String.t(), [String.t()]) :: [String.t()]
  def notification_eligible_device_ids(tenant_id, user_id, device_ids),
    do: Directory.notification_eligible_device_ids(tenant_id, user_id, device_ids)

  @doc """
  Locks the exact IdentityAccess authority used to register a push endpoint.

  The caller must already own a database transaction. The active-human user row
  is locked before its unrevoked device row so concurrent identity lifecycle
  changes use a deterministic lock order.
  """
  @spec lock_push_registration_identity(String.t(), String.t(), String.t()) ::
          :ok | {:error, :forbidden | :transaction_required}
  def lock_push_registration_identity(tenant_id, user_id, device_id),
    do: Directory.lock_push_registration_identity(tenant_id, user_id, device_id)

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
    Directory.ensure_active_user_capacity(tenant_id, policy, increment)
  end

  @doc """
  Resolves the verified tenant/user pair used to audit an authorization denial.

  Session, device, tenant, or user activity is deliberately not required: a
  revoked or suspended principal's denied privileged attempt must still be
  attributable. The user must, however, belong to the claimed tenant.
  """
  @spec authorization_audit_actor(map()) ::
          {:ok, Actor.t()} | {:error, :unknown_authorization_actor}
  def authorization_audit_actor(subject),
    do: AccessControl.authorization_audit_actor(subject)

  @doc false
  @spec audit_authorization_denial(atom(), map(), term()) :: {:error, term()}
  def audit_authorization_denial(action, subject, reason),
    do: AccessControl.audit_authorization_denial(action, subject, reason)

  @doc false
  @spec authorize_receive_user_events(map(), map()) :: :ok | {:error, :forbidden}
  def authorize_receive_user_events(subject, resource),
    do: AccessControl.authorize_receive_user_events(subject, resource)

  @doc false
  @spec authorize_administer_users(map()) :: :ok | {:error, :forbidden}
  def authorize_administer_users(subject),
    do: AccessControl.authorize_administer_users(subject)

  @doc false
  @spec authorize_manage_user_lifecycle(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_user_lifecycle(subject),
    do: AccessControl.authorize_manage_user_lifecycle(subject)

  @doc false
  @spec authorize_manage_sessions(map()) :: :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_sessions(subject),
    do: AccessControl.authorize_manage_sessions(subject)

  @doc false
  @spec authorize_view_platform_operations(map()) :: :ok | {:error, :forbidden}
  def authorize_view_platform_operations(subject),
    do: AccessControl.authorize_view_platform_operations(subject)

  @doc false
  @spec authorize_operate_platform(map()) :: :ok | {:error, :forbidden}
  def authorize_operate_platform(subject),
    do: AccessControl.authorize_operate_platform(subject)

  # Adapter-facing API. These functions are the stable projection boundary;
  # persistence-returning operations remain private owner implementations.
  def bootstrap_tenant_view(attrs) do
    Bootstrap.tenant_view(attrs, bootstrap_effects())
  end

  def authenticate_view(tenant_slug, email, password, device_attrs \\ %{}) do
    tenant_slug
    |> Sessions.authenticate(email, password, device_attrs)
    |> project_result(&CommsCore.Accounts.Projector.authentication/1)
  end

  def refresh_session_view(token) do
    token
    |> Sessions.refresh()
    |> project_result(&CommsCore.Accounts.Projector.authentication/1)
  end

  @doc """
  Rotates an unexpired guest refresh token without widening the normal human
  refresh path.
  """
  def refresh_guest_session_view(token) do
    Sessions.refresh_guest(token)
    |> project_result(&CommsCore.Accounts.Projector.authentication/1)
  end

  def access_context(session_id, request_id \\ nil) do
    with {:ok, session, tenant} <- Sessions.active_with_tenant(session_id) do
      {:ok,
       CommsCore.Accounts.Projector.access_context(
         session,
         tenant,
         Sessions.subject(session, request_id)
       )}
    end
  end

  @doc """
  Resolves a guest-only session context.

  Normal human sessions are deliberately rejected so the web adapter can use a
  separate token salt and route allowlist for guests.
  """
  def guest_access_context(session_id, request_id \\ nil) do
    with {:ok, session, tenant} <- Sessions.active_guest_with_tenant(session_id) do
      {:ok,
       CommsCore.Accounts.Projector.access_context(
         session,
         tenant,
         Sessions.subject(session, request_id)
       )}
    end
  end

  @doc """
  Provisions one expiring guest identity inside a caller-owned transaction.

  The transaction requirement lets the guest-link owner compose identity
  creation with a single conversation admission without exposing persistence.
  """
  @spec provision_guest_identity(map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :transaction_required
             | :tenant_unavailable
             | :invalid_guest_expiry
             | :active_user_quota_exceeded
             | :invalid_guest_identity}
  def provision_guest_identity(attrs) when is_map(attrs) do
    GuestIdentities.provision(attrs, guest_identity_effects())
  end

  def provision_guest_identity(attrs),
    do: GuestIdentities.provision(attrs, guest_identity_effects())

  @doc """
  Extends one active instant-room guest's authority inside a caller transaction.

  The deadline may move forward by at most 24 hours from the current time. The
  guest user, session, and device are locked and updated together; the returned
  receipt carries no persistence structs so Conversations can verify it against
  its own locked room/admission rows.
  """
  @spec extend_ephemeral_guest_authority(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok,
           %{
             tenant_id: Ecto.UUID.t(),
             user_id: Ecto.UUID.t(),
             session_id: Ecto.UUID.t(),
             expires_at: DateTime.t()
           }}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  def extend_ephemeral_guest_authority(session_id, deadline) when is_binary(session_id) do
    GuestIdentities.extend_ephemeral_authority(session_id, deadline)
  end

  def extend_ephemeral_guest_authority(session_id, deadline),
    do: GuestIdentities.extend_ephemeral_authority(session_id, deadline)

  @doc """
  Ensures one active instant-room guest remains authorized through a deadline.

  Unlike `extend_ephemeral_guest_authority/2`, this transaction-only command is
  idempotent when the guest already has a later authority window. It never
  shortens user or session authority and returns the requested deadline as a
  coverage receipt.
  """
  @spec ensure_ephemeral_guest_authority(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok,
           %{
             tenant_id: Ecto.UUID.t(),
             user_id: Ecto.UUID.t(),
             session_id: Ecto.UUID.t(),
             expires_at: DateTime.t()
           }}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  def ensure_ephemeral_guest_authority(session_id, deadline) when is_binary(session_id) do
    GuestIdentities.ensure_ephemeral_authority(session_id, deadline)
  end

  def ensure_ephemeral_guest_authority(session_id, deadline),
    do: GuestIdentities.ensure_ephemeral_authority(session_id, deadline)

  @doc """
  Reissues creator authentication after an instant-room creation response is
  lost and safely replayed.

  Conversations must first lock and verify the idempotency record, room, and
  creator admission. This transaction-only command keeps the guest user and
  device stable, revokes the prior refresh authority without broadcasting a
  socket disconnect, and returns a fresh guest session/refresh credential.
  """
  @spec resume_ephemeral_guest_identity(map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :transaction_required
             | :forbidden
             | :session_expired
             | :tenant_unavailable
             | :invalid_ephemeral_guest_deadline
             | :invalid_guest_identity}
  def resume_ephemeral_guest_identity(command) when is_map(command) do
    GuestIdentities.resume_ephemeral(command, guest_identity_effects())
  end

  def resume_ephemeral_guest_identity(command),
    do: GuestIdentities.resume_ephemeral(command, guest_identity_effects())

  @doc """
  Atomically converts a guest into a normal human account without changing the
  user id.

  It can participate in an existing guest-admission transaction or open its own
  transaction when invoked directly.
  """
  @spec convert_guest_account(map(), map(), String.t()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :forbidden
             | :guest_account_conversion_email_mismatch
             | :session_expired
             | :tenant_unavailable
             | :weak_password
             | :invalid_guest_account}
  def convert_guest_account(attrs, guest_subject, preauthorized_email)
      when is_map(attrs) and is_map(guest_subject) and is_binary(preauthorized_email) do
    GuestIdentities.convert(attrs, guest_subject, preauthorized_email, guest_identity_effects())
  end

  def convert_guest_account(attrs, guest_subject, preauthorized_email),
    do:
      GuestIdentities.convert(
        attrs,
        guest_subject,
        preauthorized_email,
        guest_identity_effects()
      )

  @doc """
  Converts a domain-authorized instant-room guest into a conversation-only
  human. The submitted email remains unverified.

  Conversations must call this from its locked admission transaction and add
  the internal `:ephemeral_room` authority-purpose claim after verifying the
  room. The original session is revoked for HTTP/refresh use, but no socket or
  call disconnect is emitted; the adapter can complete a bounded socket handoff
  to the replacement session first.
  """
  @spec convert_ephemeral_guest_account(map(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :forbidden
             | :transaction_required
             | :session_expired
             | :tenant_unavailable
             | :weak_password
             | :invalid_guest_account}
  def convert_ephemeral_guest_account(attrs, guest_subject)
      when is_map(attrs) and is_map(guest_subject) do
    GuestIdentities.convert_ephemeral(attrs, guest_subject, guest_identity_effects())
  end

  def convert_ephemeral_guest_account(attrs, guest_subject),
    do: GuestIdentities.convert_ephemeral(attrs, guest_subject, guest_identity_effects())

  @doc """
  Revokes an expiring guest session and propagates the revocation to active
  calls. The operation is safe both standalone and inside a caller transaction.
  """
  @spec revoke_guest_session(Ecto.UUID.t(), String.t()) ::
          :ok | {:error, :not_found | :invalid_reason | term()}
  def revoke_guest_session(session_id, reason)
      when is_binary(session_id) and is_binary(reason) do
    GuestIdentities.revoke_session(session_id, reason, guest_identity_effects())
  end

  def revoke_guest_session(session_id, reason),
    do: GuestIdentities.revoke_session(session_id, reason, guest_identity_effects())

  def list_tenant_user_views(subject) do
    UserLifecycle.list_tenant_views(subject)
  end

  def list_admin_user_views(subject) do
    UserLifecycle.list_admin_views(subject)
  end

  def update_profile_view(attrs, subject),
    do: UserLifecycle.update_profile_view(attrs, subject)

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
    UserLifecycle.change_with_effects_view(id, attrs, subject, user_lifecycle_effects())
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
  def validate_invitation_password(password), do: Invitations.validate_password(password)

  @doc false
  @impl CommsCore.Administration.InvitationIdentityPort
  def authorize_invitation(%InvitationIdentityAuthorization{} = authorization) do
    Invitations.authorize(authorization)
  end

  @doc false
  @impl CommsCore.Administration.InvitationIdentityPort
  def ensure_invitation_identity_available(tenant_id, email)
      when is_binary(tenant_id) and is_binary(email) do
    Invitations.ensure_identity_available(tenant_id, email)
  end

  @doc false
  @impl CommsCore.Administration.InvitationIdentityPort
  def enroll_invited_user(%InvitedUserCommand{} = command) do
    Invitations.enroll(command)
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
             | :user_erasure_failed}
  def erase_user_for_governance(command) when is_map(command) do
    GovernanceErasure.erase(command)
  end

  def erase_user_for_governance(command), do: GovernanceErasure.erase(command)

  def bootstrap_tenant(attrs) when is_map(attrs) do
    Bootstrap.tenant(attrs, bootstrap_effects())
  end

  @doc """
  Creates the first tenant owner without creating a browser session.

  The operation is serialized in PostgreSQL so a retried release Job is safe.
  Once a tenant exists, only the same normalized tenant slug and owner email are
  accepted as an idempotent retry; a different bootstrap identity fails closed.
  """
  def bootstrap_tenant_once(attrs) when is_map(attrs) do
    Bootstrap.tenant_once(attrs, bootstrap_effects())
  end

  @doc """
  Deletes one release-qualification tenant after verifying its exact owner marker.

  This bounded lifecycle operation is used only by the one-shot release
  qualifier. TenantAdministration retains the tenant row and cascading-delete
  ownership; IdentityAccess verifies that the expected active owner is the
  tenant's only owner before requesting deletion.
  """
  def delete_release_qualification_tenant(attrs) when is_map(attrs) do
    Bootstrap.delete_release_qualification_tenant(attrs)
  end

  def delete_release_qualification_tenant(attrs),
    do: Bootstrap.delete_release_qualification_tenant(attrs)

  def create_user(attrs, subject) when is_map(attrs) and is_map(subject) do
    UserLifecycle.create(attrs, subject)
  end

  def refresh_session(token) when is_binary(token) do
    Sessions.refresh(token)
  end

  def get_active_session(id) when is_binary(id) do
    Sessions.get_active(id)
  end

  def issue_socket_ticket(subject) when is_map(subject) do
    Sessions.issue_socket_ticket(subject)
  end

  @doc """
  Issues a guest-scoped one-time socket ticket.

  Conversation and admission ids originate from the already verified guest
  access token and are persisted as opaque ticket scope so websocket
  consumption cannot widen the guest to another conversation.
  """
  def issue_guest_socket_ticket(subject) when is_map(subject) do
    Sessions.issue_guest_socket_ticket(subject)
  end

  def issue_guest_socket_ticket(_subject), do: {:error, :invalid_access_token}

  def consume_socket_ticket(ticket) when is_binary(ticket) do
    Sessions.consume_socket_ticket(ticket)
  end

  def consume_socket_ticket(_ticket), do: {:error, :invalid_socket_ticket}

  def revoke_session(session_id, user_id) do
    Sessions.revoke(session_id, user_id, session_effects())
  end

  def list_admin_users(subject) do
    UserLifecycle.list_admin(subject)
  end

  def update_profile(attrs, subject) when is_map(attrs) and is_map(subject) do
    UserLifecycle.update_profile(attrs, subject)
  end

  def change_password(attrs, subject) when is_map(attrs) and is_map(subject) do
    Sessions.change_password(attrs, subject, session_effects())
  end

  def change_password_with_effects(attrs, subject) when is_map(attrs) and is_map(subject) do
    Sessions.change_password_with_effects(attrs, subject, session_effects())
  end

  def step_up(attrs, subject) when is_map(attrs) and is_map(subject) do
    Sessions.step_up(attrs, subject)
  end

  def list_devices(subject) do
    Sessions.list_devices(subject)
  end

  def list_sessions(subject) do
    Sessions.list_sessions(subject)
  end

  def revoke_device(device_id, subject) do
    Sessions.revoke_device(device_id, subject, session_effects())
  end

  def revoke_own_session(session_id, subject) do
    Sessions.revoke_own(session_id, subject, session_effects())
  end

  def list_user_sessions(user_id, subject) do
    Sessions.list_user_sessions(user_id, subject)
  end

  def admin_revoke_session(user_id, session_id, attrs, subject) when is_map(attrs) do
    Sessions.admin_revoke(user_id, session_id, attrs, subject, session_effects())
  end

  def change_user(user_id, attrs, subject) when is_map(attrs) and is_map(subject) do
    UserLifecycle.change(user_id, attrs, subject, user_lifecycle_effects())
  end

  def change_user_with_effects(user_id, attrs, subject)
      when is_map(attrs) and is_map(subject) do
    UserLifecycle.change_with_effects(user_id, attrs, subject, user_lifecycle_effects())
  end

  @doc false
  def preflight_user_lifecycle_change(user_id, attrs, subject)
      when is_map(attrs) and is_map(subject) do
    UserLifecycle.preflight(user_id, attrs, subject)
  end

  def preflight_user_lifecycle_change(_user_id, _attrs, _subject),
    do: UserLifecycle.preflight(nil, nil, nil)

  @doc """
  Applies a governed user-lifecycle change inside a caller-owned transaction.

  The caller supplies only user identifiers excluded from the active-owner
  calculation. IdentityAccess owns authorization, locking, mutation, access
  revocation, audit, and the returned projection.
  """
  @spec apply_user_lifecycle_change(Ecto.UUID.t(), map(), map(), [Ecto.UUID.t()]) ::
          {:ok, %{user: CommsCore.Accounts.UserView.t(), revoked_session_ids: [Ecto.UUID.t()]}}
          | {:error,
             ValidationError.t()
             | :invalid_owner_exclusions
             | :not_found
             | :transaction_required
             | atom()}
  def apply_user_lifecycle_change(user_id, attrs, subject, excluded_owner_ids)
      when is_map(attrs) and is_map(subject) do
    UserLifecycle.apply_change(
      user_id,
      attrs,
      subject,
      excluded_owner_ids,
      user_lifecycle_effects()
    )
  end

  def apply_user_lifecycle_change(_user_id, _attrs, _subject, _excluded_owner_ids),
    do: UserLifecycle.apply_change(nil, nil, nil, nil, user_lifecycle_effects())

  def get_user_for_subject(subject) do
    UserLifecycle.get_for_subject(subject)
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
    PlatformGrants.set_from_console(user_id, role, attrs)
  end

  def set_platform_role_from_console(_user_id, _role, _attrs),
    do: PlatformGrants.set_from_console(nil, nil, nil)

  def subject_for_session(%Session{} = session, request_id \\ nil) do
    Sessions.subject(session, request_id)
  end

  defp session_effects do
    %{
      revoke_sessions: &revoke_sessions_for_session_boundary/3,
      revoke_device: &revoke_device_for_session_boundary/3,
      notify_device_revoked: &notify_device_revoked_for_session_boundary/3
    }
  end

  defp bootstrap_effects do
    %{
      append_initial_channel: &append_initial_channel_for_bootstrap/3,
      create_initial_channel: &create_initial_channel_for_bootstrap/1,
      fetch_initial_channel: &fetch_initial_channel_for_bootstrap/2
    }
  end

  defp guest_identity_effects do
    %{
      active_tenant: &Administration.active_tenant/1,
      revoke_identity_access: &revoke_identity_access_for_account_boundary/1,
      validation_error?: &validation_error?/1,
      validation_error_from_changeset: &validation_error_from_changeset/1
    }
  end

  defp user_lifecycle_effects do
    %{
      notify_identity_access_revoked: &notify_identity_access_revoked/1,
      revoke_identity_access: &revoke_identity_access_for_account_boundary/1,
      validation_error_from_changeset: &validation_error_from_changeset/1
    }
  end

  defp append_initial_channel_for_bootstrap(multi, name, command) do
    ConversationBootstrapPort.append_initial_channel(multi, name, command)
  end

  defp create_initial_channel_for_bootstrap(command) do
    ConversationBootstrapPort.create_initial_channel(command)
  end

  defp fetch_initial_channel_for_bootstrap(tenant_id, owner_user_id) do
    ConversationBootstrapPort.fetch_initial_channel(tenant_id, owner_user_id)
  end

  defp revoke_identity_access_for_account_boundary(command) do
    command
    |> CallLifecyclePort.revoke_identity_access()
    |> call_lifecycle_ok!()
  end

  defp notify_identity_access_revoked(command) do
    command
    |> NotificationPort.execute()
    |> notification_ok!()
  end

  defp validation_error_from_changeset(changeset) do
    {:ok, error} = ValidationError.from(changeset)
    error
  end

  defp validation_error?(%ValidationError{}), do: true
  defp validation_error?(_reason), do: false

  defp revoke_sessions_for_session_boundary(tenant_id, session_ids, reason) do
    CallLifecycleCommand.sessions_revoked(tenant_id, session_ids, reason)
    |> CallLifecyclePort.revoke_identity_access()
    |> call_lifecycle_ok!()
  end

  defp revoke_device_for_session_boundary(tenant_id, device_id, reason) do
    CallLifecycleCommand.device_revoked(tenant_id, device_id, reason)
    |> CallLifecyclePort.revoke_identity_access()
    |> call_lifecycle_ok!()
  end

  defp notify_device_revoked_for_session_boundary(tenant_id, user_id, device_id) do
    NotificationCommand.device_revoked(tenant_id, user_id, device_id)
    |> NotificationPort.execute()
    |> notification_ok!()
  end

  defp call_lifecycle_ok!({:ok, %CallLifecycleReceipt{}}), do: :ok
  defp call_lifecycle_ok!({:error, reason}), do: Repo.rollback(reason)

  defp notification_ok!(:ok), do: :ok
  defp notification_ok!({:error, reason}), do: Repo.rollback(reason)
  defp notification_ok!(_unexpected), do: Repo.rollback(:notification_delivery_unavailable)

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error
end
