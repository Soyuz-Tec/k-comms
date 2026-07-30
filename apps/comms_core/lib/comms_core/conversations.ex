defmodule CommsCore.Conversations do
  import Ecto.Query

  @default_channel_limit 25
  @max_channel_limit 100

  alias CommsCore.{
    Accounts,
    Administration,
    AdmissionQuotas,
    Outbox,
    Repo,
    RuntimePorts,
    ServiceAccounts
  }

  alias CommsCore.Accounts.{
    ConversationBootstrapPort,
    InitialConversationCommand
  }

  alias CommsCore.Audit

  alias CommsCore.Conversations.{
    AdmissionUsage,
    AdmissionUsageQuery,
    AvailabilityQuery,
    Bootstrap,
    CallAccess,
    CallConversation,
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    CallMembership,
    ContentAccess,
    Conversation,
    ConversationView,
    DataLifecycle,
    Membership,
    MessageWriteSlot
  }

  alias CommsCore.Conversations.ReleaseFingerprint

  @behaviour ConversationBootstrapPort

  @doc false
  def release_tenant_fingerprint_fragment(repo, tenant_id),
    do: ReleaseFingerprint.fragment(repo, tenant_id)

  @doc """
  Implements the IdentityAccess bootstrap port inside the caller's transaction.

  Both rows remain owned and persisted by Conversations. The returned receipt
  contains only the IdentityAccess-owned bootstrap projection fields.
  """
  @impl ConversationBootstrapPort
  def create_initial_channel(%InitialConversationCommand{} = command),
    do: Bootstrap.create_initial_channel(command)

  @impl ConversationBootstrapPort
  def fetch_initial_channel(tenant_id, owner_user_id),
    do: Bootstrap.fetch_initial_channel(tenant_id, owner_user_id)

  @doc """
  Lists active conversations for a service identity with directory scope.

  IdentityAccess validates the durable service credential and scope;
  Conversations owns membership and archive filtering and returns only views.
  """
  @spec list_for_service(map()) :: {:ok, [ConversationView.t()]} | {:error, :forbidden}
  def list_for_service(subject) when is_map(subject) do
    with :ok <- ServiceAccounts.authorize_service(subject, "conversations:read") do
      {:ok, list_for_user_views(subject)}
    end
  end

  def list_for_service(_subject), do: {:error, :forbidden}

  @doc """
  Authorizes a scoped service identity against owner-local conversation state.

  The credential and requested capability are revalidated by IdentityAccess.
  Conversations then requires an active same-tenant membership and a
  non-archived conversation. Every failure is intentionally indistinguishable.
  """
  @spec authorize_service_access(map(), String.t(), Ecto.UUID.t()) ::
          :ok | {:error, :forbidden}
  def authorize_service_access(subject, required_scope, conversation_id)
      when is_map(subject) and is_binary(required_scope) and is_binary(conversation_id) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         :ok <- ServiceAccounts.authorize_service(subject, required_scope),
         true <- active_service_membership?(subject, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_service_access(_subject, _required_scope, _conversation_id),
    do: {:error, :forbidden}

  @doc """
  Authorizes creation using the active identity projection owned by
  `CommsCore.Accounts`.
  """
  @spec authorize_create(map()) :: :ok | {:error, :forbidden}
  def authorize_create(subject) when is_map(subject) do
    with {:ok, %{account_type: :human, access_scope: :workspace}} <-
           Accounts.access_grant(subject) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_create(_subject), do: {:error, :forbidden}

  @doc """
  Authorizes discovery of tenant-visible channels without exposing either
  identity or conversation persistence structs.
  """
  @spec authorize_discovery(map()) ::
          :ok | {:error, :forbidden | :public_channels_disabled}
  def authorize_discovery(subject) when is_map(subject) do
    with {:ok, %{account_type: :human, access_scope: :workspace}} <-
           Accounts.access_grant(subject),
         :ok <- public_channels_enabled(subject) do
      :ok
    else
      {:error, :public_channels_disabled} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize_discovery(_subject), do: {:error, :forbidden}

  @doc """
  Authorizes self-service entry into a tenant-visible channel.
  """
  @spec authorize_join(Ecto.UUID.t(), map()) ::
          :ok | {:error, :forbidden | :public_channels_disabled}
  def authorize_join(conversation_id, subject),
    do: authorize_public_channel(:join, conversation_id, subject)

  @doc """
  Authorizes self-service departure from a tenant-visible channel.

  Disabling public channels intentionally does not trap existing members.
  """
  @spec authorize_leave(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_leave(conversation_id, subject),
    do: authorize_public_channel(:leave, conversation_id, subject)

  @doc "Authorizes access that requires an active conversation membership."
  @spec authorize_read(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_read(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc """
  Returns the active membership facts consumed by Calls authorization.

  The projection contains no conversation or membership persistence struct.
  Missing, cross-tenant, departed, and archived membership scopes fail closed.
  """
  @spec call_membership(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, CallMembership.t()} | {:error, :forbidden}
  def call_membership(tenant_id, conversation_id, user_id),
    do: CallAccess.call_membership(tenant_id, conversation_id, user_id)

  @doc """
  Locks an active conversation for Calls transaction coordination.

  The caller must acquire TenantAdministration's tenant lock first. `:share`
  protects a join; `:update` serializes start-and-join creation.
  """
  @spec lock_call_conversation(Ecto.UUID.t(), Ecto.UUID.t(), :share | :update) ::
          {:ok, CallConversation.t()} | {:error, :forbidden | :transaction_required}
  def lock_call_conversation(tenant_id, conversation_id, lock_mode),
    do: CallAccess.lock_call_conversation(tenant_id, conversation_id, lock_mode)

  @doc """
  Locks and returns an active Calls membership after the conversation lock.
  """
  @spec lock_call_membership(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, CallMembership.t()} | {:error, :forbidden | :transaction_required}
  def lock_call_membership(tenant_id, conversation_id, user_id),
    do: CallAccess.lock_call_membership(tenant_id, conversation_id, user_id)

  @doc "Authorizes sending message content to a conversation."
  @spec authorize_send_message(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_send_message(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc "Authorizes advancing the subject's read cursor."
  @spec authorize_mark_read(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_mark_read(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc "Authorizes reacting to message content in a conversation."
  @spec authorize_react_message(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_react_message(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc "Authorizes attaching content to a conversation."
  @spec authorize_upload_attachment(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_upload_attachment(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc """
  Authorizes ordinary conversation administration.

  Conversation owners and moderators may manage any conversation they actively
  belong to. Tenant owners and administrators may additionally manage
  tenant-visible channels. Denials for an otherwise active identity are
  recorded through the Audit facade.
  """
  @spec authorize_manage(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_manage(conversation_id, subject),
    do: authorize_management(:manage_conversation, conversation_id, subject)

  @doc """
  Authorizes ownership changes using the stricter owner policy.
  """
  @spec authorize_manage_ownership(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_manage_ownership(conversation_id, subject),
    do: authorize_management(:manage_conversation_ownership, conversation_id, subject)

  @doc """
  Creates a revocable, expiring guest link for a group or channel.

  The returned token is deliberately available only in this creation result;
  persisted and subsequently listed projections contain only its digest-free
  metadata.
  """
  def create_guest_link_view(conversation_id, attrs, subject),
    do: CommsCore.Conversations.GuestAccess.create_link(conversation_id, attrs, subject)

  @doc "Lists secret-free guest-link projections for a managed conversation."
  def list_guest_link_views(conversation_id, subject),
    do: CommsCore.Conversations.GuestAccess.list_links(conversation_id, subject)

  @doc "Revokes a guest link and all temporary admissions derived from it."
  def revoke_guest_link_view(conversation_id, link_id, subject),
    do:
      CommsCore.Conversations.GuestAccess.revoke_link(
        conversation_id,
        link_id,
        subject,
        &revoke_guest_membership_call_access/4
      )

  @doc "Returns the non-sensitive preview for an available guest link."
  def preview_guest_link(token),
    do: CommsCore.Conversations.GuestAccess.preview_link(token)

  @doc "Atomically redeems a guest link into a bounded identity and membership."
  def redeem_guest_link(token, attrs),
    do: CommsCore.Conversations.GuestAccess.redeem_link(token, attrs)

  @doc "Resolves an active guest admission without granting ordinary account access."
  def resolve_guest_access(subject, conversation_id),
    do: CommsCore.Conversations.GuestAccess.resolve_access(subject, conversation_id)

  @doc "Rehydrates the active conversation scope for a refreshed guest session."
  def guest_scope_for_session(session_id),
    do: CommsCore.Conversations.GuestAccess.scope_for_session(session_id)

  @doc "Converts an active guest into a normal account while preserving membership."
  def convert_guest_account(attrs, guest_subject),
    do: CommsCore.Conversations.GuestAccess.convert_account(attrs, guest_subject)

  @doc "Atomically revokes a guest session, admission, membership, and active room presence."
  def logout_guest_session(guest_subject),
    do:
      CommsCore.Conversations.GuestAccess.logout_session(
        guest_subject,
        &revoke_guest_membership_call_access/4
      )

  @doc "Creates an instant room for either a trusted public-tenant guest or a workspace human."
  def create_ephemeral_room(attrs, creator),
    do: CommsCore.Conversations.EphemeralRooms.create(attrs, creator)

  @doc "Returns the public, non-sensitive preview for an instant-room join token."
  def preview_ephemeral_room(token),
    do: CommsCore.Conversations.EphemeralRooms.preview(token)

  @doc "Joins an instant room as either a guest or a same-tenant human."
  def join_ephemeral_room(token, attrs, joiner),
    do: CommsCore.Conversations.EphemeralRooms.join(token, attrs, joiner)

  @doc "Opens a durable, cluster-safe presence lease for an authenticated room member."
  def open_ephemeral_presence(attrs),
    do: CommsCore.Conversations.EphemeralRooms.open_presence(attrs)

  @doc "Renews an existing durable instant-room presence lease."
  def heartbeat_ephemeral_presence(attrs),
    do: CommsCore.Conversations.EphemeralRooms.heartbeat_presence(attrs)

  @doc "Closes a durable presence lease and schedules generation-fenced reconciliation."
  def close_ephemeral_presence(attrs),
    do: CommsCore.Conversations.EphemeralRooms.close_presence(attrs)

  @doc "Returns an instant-room projection for an existing conversation membership."
  def ephemeral_room_for_conversation(conversation_id, subject),
    do: CommsCore.Conversations.EphemeralRooms.room_for_conversation(conversation_id, subject)

  @doc false
  @spec reconcile_ephemeral_room(Ecto.UUID.t(), pos_integer(), module()) ::
          {:ok,
           :active
           | :already_terminal
           | :stale_generation
           | {:idle, DateTime.t(), pos_integer()}}
          | {:error, term()}
  def reconcile_ephemeral_room(room_id, expected_generation, caller),
    do:
      CommsCore.Conversations.EphemeralRooms.reconcile(
        room_id,
        expected_generation,
        caller
      )

  @doc false
  @spec reconcile_ephemeral_rooms(module()) ::
          {:ok, %{scanned: non_neg_integer(), reconciled: non_neg_integer()}}
          | {:error, :forbidden}
  def reconcile_ephemeral_rooms(caller),
    do: CommsCore.Conversations.EphemeralRooms.reconcile_all(caller)

  @doc false
  @spec expire_ephemeral_room(Ecto.UUID.t(), pos_integer(), module()) ::
          {:ok,
           :expired
           | :already_terminal
           | :active
           | :stale_generation
           | {:not_due, pos_integer()}}
          | {:error, term()}
  def expire_ephemeral_room(room_id, expected_generation, caller) do
    CommsCore.Conversations.EphemeralRooms.expire(
      room_id,
      expected_generation,
      caller,
      &revoke_guest_membership_call_access/4
    )
  end

  @doc false
  def persisted_ephemeral_room_count,
    do: CommsCore.Conversations.EphemeralRooms.persisted_room_count()

  @doc false
  def persisted_ephemeral_presence_lease_count,
    do: CommsCore.Conversations.EphemeralRooms.persisted_presence_lease_count()

  @doc false
  def persisted_ephemeral_join_receipt_count,
    do: CommsCore.Conversations.EphemeralRooms.persisted_join_receipt_count()

  @doc false
  @spec expire_guest_admission(Ecto.UUID.t(), module()) ::
          {:ok, :expired | :already_terminal | {:not_due, pos_integer()}}
          | {:error, :forbidden | :guest_admission_not_found | term()}
  def expire_guest_admission(admission_id, caller) when is_binary(admission_id) do
    if RuntimePorts.authorized_job_worker?(:guest_admission_expiry, caller) do
      CommsCore.Conversations.GuestAccess.expire_admission(
        admission_id,
        &revoke_guest_membership_call_access/4
      )
    else
      {:error, :forbidden}
    end
  end

  def expire_guest_admission(_admission_id, _caller), do: {:error, :forbidden}

  @doc false
  def revoke_guest_membership_call_access(tenant_id, conversation_id, user_id, reason)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_binary(user_id) and
             is_binary(reason) do
    if Repo.in_transaction?() do
      case tenant_id
           |> CallLifecycleCommand.membership_revoked(conversation_id, user_id, reason)
           |> CallLifecyclePort.revoke_conversation_access() do
        {:ok, %CallLifecycleReceipt{}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :transaction_required}
    end
  end

  def revoke_guest_membership_call_access(
        _tenant_id,
        _conversation_id,
        _user_id,
        _reason
      ),
      do: {:error, :forbidden}

  @doc """
  Returns conversation-owned capacity counts for approved read-model composition.
  """
  @spec admission_usage(Ecto.UUID.t()) :: AdmissionUsage.t()
  def admission_usage(tenant_id), do: AdmissionUsageQuery.get(tenant_id)

  @doc """
  Archives a tenant-scoped conversation as part of an existing erasure transaction.

  Returns the number of archived rows and never exposes the Conversation schema.
  """
  @spec archive_for_erasure(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_erasure_scope | :transaction_required}
  def archive_for_erasure(tenant_id, conversation_id, timestamp),
    do: DataLifecycle.archive_for_erasure(tenant_id, conversation_id, timestamp)

  @doc """
  Ends a user's active tenant memberships as part of an existing erasure transaction.

  Returns the number of memberships changed and never exposes Membership schemas.
  """
  @spec remove_user_memberships_for_erasure(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_erasure_scope | :transaction_required}
  def remove_user_memberships_for_erasure(tenant_id, user_id, timestamp),
    do: DataLifecycle.remove_user_memberships_for_erasure(tenant_id, user_id, timestamp)

  @doc """
  Reserves the next message sequence while participating in the caller's transaction.

  This owner-contributed operation keeps the conversation row lock and mutation
  inside Conversations. The surrounding transaction must roll back if later
  message-content work fails.
  """
  @spec reserve_message_slot(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MessageWriteSlot.t()}
          | {:error,
             :conversation_not_found | :message_slot_update_failed | :transaction_required}
  def reserve_message_slot(tenant_id, conversation_id),
    do: ContentAccess.reserve_message_slot(tenant_id, conversation_id)

  @doc """
  Validates that every supplied user is an active member of the conversation.

  Membership persistence stays inside Conversations. IdentityAccess resolves
  active user IDs through its facade; content callers exchange only identifiers
  and the validation result.
  """
  @spec validate_active_members(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          :ok | {:error, :invalid_mentions}
  def validate_active_members(tenant_id, conversation_id, user_ids),
    do: ContentAccess.validate_active_members(tenant_id, conversation_id, user_ids)

  @doc """
  Validates an exact tenant-scoped conversation reference.

  The result contains no conversation persistence details and intentionally
  treats malformed, missing, and foreign-tenant identifiers as not found.
  Archived conversations remain valid references while their row exists.
  """
  @spec validate_reference(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def validate_reference(tenant_id, conversation_id),
    do: DataLifecycle.validate_reference(tenant_id, conversation_id)

  @doc """
  Returns every conversation ID in a tenant's retention scope.

  Archived conversations remain in scope, matching the durable conversation
  rows considered by retention processing. IDs are returned deterministically
  without exposing conversation persistence.
  """
  @spec retention_scope_ids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def retention_scope_ids(tenant_id), do: DataLifecycle.retention_scope_ids(tenant_id)

  @doc """
  Returns the composable active-membership authorization projection for a
  verified identity grant.

  The projection remains owned by Conversations and exposes only the
  conversation identifier and the caller's current membership role. Dependent
  contexts join it as a database subquery so authorization remains bounded even
  when a user belongs to many conversations; no persistence struct or
  materialized identifier list crosses the boundary.
  """
  @spec active_membership_authorization_query(CommsCore.Accounts.AccessGrant.t()) ::
          Ecto.Query.t()
  def active_membership_authorization_query(%CommsCore.Accounts.AccessGrant{
        tenant_id: tenant_id,
        user_id: user_id
      }) do
    active_membership_authorization_query(tenant_id, user_id)
  end

  @doc """
  Returns the same composable authorization projection for a verified service
  identity.

  IdentityAccess revalidates the durable service credential and requested
  capability before Conversations exposes its owner-local membership query.
  Invalid identity facts fail closed before any dependent context can execute
  the projection.
  """
  @spec active_service_membership_authorization_query(map(), String.t()) ::
          {:ok, Ecto.Query.t()} | {:error, :forbidden}
  def active_service_membership_authorization_query(subject, required_scope)
      when is_map(subject) and is_binary(required_scope) do
    with :ok <- ServiceAccounts.authorize_service(subject, required_scope),
         {:ok, tenant_id} <- Ecto.UUID.cast(value(subject, :tenant_id)),
         {:ok, user_id} <- Ecto.UUID.cast(value(subject, :user_id)) do
      {:ok, active_membership_authorization_query(tenant_id, user_id)}
    else
      _ -> {:error, :forbidden}
    end
  end

  def active_service_membership_authorization_query(_subject, _required_scope),
    do: {:error, :forbidden}

  defp active_membership_authorization_query(tenant_id, user_id) do
    unavailable_conversations = AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

    from(conversation in Conversation,
      join: membership in Membership,
      on:
        membership.conversation_id == conversation.id and
          membership.tenant_id == conversation.tenant_id,
      where:
        conversation.tenant_id == ^tenant_id and membership.user_id == ^user_id and
          is_nil(membership.left_at) and is_nil(conversation.archived_at) and
          conversation.id not in subquery(unavailable_conversations),
      select: %{
        conversation_id: conversation.id,
        membership_role: membership.role
      }
    )
  end

  @doc """
  Checks one conversation against the same active-membership projection.

  This preserves a fail-closed response for explicitly scoped reads without
  loading every authorized conversation identifier into application memory.
  """
  @spec active_conversation_member?(
          CommsCore.Accounts.AccessGrant.t(),
          Ecto.UUID.t()
        ) :: boolean()
  def active_conversation_member?(
        %CommsCore.Accounts.AccessGrant{} = grant,
        conversation_id
      ) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} ->
        grant
        |> active_membership_authorization_query()
        |> subquery()
        |> where([authorization], authorization.conversation_id == ^conversation_id)
        |> Repo.exists?()

      :error ->
        false
    end
  end

  @doc false
  def project(%Conversation{} = conversation),
    do: CommsCore.Conversations.Projector.conversation(conversation)

  def project(%ConversationView{} = conversation), do: conversation

  def create_view(attrs, subject) do
    create(attrs, subject)
    |> project_result(&project_authorized_conversation(&1, subject))
  end

  def list_for_user_views(subject) do
    results = list_for_user(subject)
    counterparts = direct_counterparts(results, subject)

    Enum.map(results, fn result ->
      CommsCore.Conversations.Projector.user_conversation(
        result,
        Map.get(counterparts, result.conversation.id)
      )
    end)
  end

  def discover_public_channel_views(params, subject) do
    with {:ok, result} <- discover_public_channels(params, subject) do
      {:ok,
       %{
         result
         | channels:
             Enum.map(result.channels, &CommsCore.Conversations.Projector.public_channel/1)
       }}
    end
  end

  def join_public_channel_view(id, subject),
    do: join_public_channel(id, subject) |> project_result(&project_membership_change/1)

  def leave_public_channel_view(id, attrs, subject),
    do: leave_public_channel(id, attrs, subject) |> project_result(&project_membership_change/1)

  def get_for_user_view(id, subject) do
    get_for_user(id, subject)
    |> project_result(&project_authorized_user_conversation(&1, subject))
  end

  def update_view(id, attrs, subject) do
    __MODULE__.update(id, attrs, subject)
    |> project_result(&project_authorized_conversation(&1, subject))
  end

  def archive_view(id, attrs, subject) do
    archive(id, attrs, subject)
    |> project_result(&project_authorized_conversation(&1, subject))
  end

  def list_member_views(id, subject) do
    with {:ok, members} <- list_members(id, subject) do
      {:ok, Enum.map(members, &CommsCore.Conversations.Projector.membership/1)}
    end
  end

  def add_member_view(conversation_id, user_id, role, subject),
    do:
      add_member(conversation_id, user_id, role, subject)
      |> project_result(&CommsCore.Conversations.Projector.membership/1)

  def remove_member_view(conversation_id, user_id, attrs, subject),
    do:
      remove_member(conversation_id, user_id, attrs, subject)
      |> project_result(&CommsCore.Conversations.Projector.membership/1)

  def change_member_role_view(conversation_id, user_id, attrs, subject),
    do:
      change_member_role(conversation_id, user_id, attrs, subject)
      |> project_result(&CommsCore.Conversations.Projector.membership/1)

  @doc """
  Returns the caller's active direct conversation with another active human or
  creates it atomically.

  The tenant admission lock serializes this operation with all other
  conversation creation and user lifecycle admission. Existing conversations
  are resolved before quota checks, so reaching capacity never prevents
  members from resuming an already-authorized direct conversation.
  """
  @spec get_or_create_direct_view(Ecto.UUID.t(), map()) ::
          {:ok, %{conversation: ConversationView.t(), created: boolean()}}
          | {:error,
             :active_conversation_quota_exceeded
             | :conversation_member_quota_exceeded
             | :direct_conversation_unavailable
             | :forbidden
             | :not_found}
  def get_or_create_direct_view(other_user_id, subject)
      when is_binary(other_user_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, other_user_id} <- Ecto.UUID.cast(other_user_id),
         false <- grant.user_id == other_user_id do
      Repo.transaction(fn ->
        policy = admission_policy!(grant.tenant_id)
        locked_grant = lock_direct_access!(subject, grant)
        member_ids = Enum.sort([locked_grant.user_id, other_user_id])

        lock_directory_members!(locked_grant.tenant_id, member_ids)

        {:ok, direct_key} = direct_key(:direct, member_ids)

        case lock_direct_conversation(locked_grant.tenant_id, direct_key) do
          %Conversation{archived_at: nil} = conversation ->
            ensure_active_direct_memberships!(conversation, member_ids)

            %{conversation: conversation, created: false}

          %Conversation{} ->
            Repo.rollback(:direct_conversation_unavailable)

          nil ->
            quota_ok!(
              AdmissionQuotas.check_conversation_creation(
                policy,
                active_conversation_count(locked_grant.tenant_id),
                2
              )
            )

            conversation =
              create_direct_conversation!(
                locked_grant.tenant_id,
                locked_grant.user_id,
                member_ids,
                direct_key,
                subject
              )

            %{conversation: conversation, created: true}
        end
      end)
      |> transaction_result()
      |> project_direct_conversation_result(subject)
    else
      {:error, _reason} -> {:error, :forbidden}
      true -> {:error, :not_found}
      :error -> {:error, :not_found}
    end
  end

  def get_or_create_direct_view(_other_user_id, _subject), do: {:error, :not_found}

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    kind = enum_value(value(attrs, :kind), [:direct, :group, :channel], :group)
    member_ids = normalize_member_ids(value(attrs, :member_ids), user_id)

    visibility = enum_value(value(attrs, :visibility), [:private, :tenant], :private)
    visibility = if kind == :direct, do: :private, else: visibility
    title = if kind == :direct, do: nil, else: value(attrs, :title)

    with :ok <- authorize_create(subject),
         :ok <- validate_members(tenant_id, member_ids),
         :ok <- validate_public_channel(subject, kind, visibility),
         {:ok, direct_key} <- direct_key(kind, member_ids) do
      now = now()

      Repo.transaction(fn ->
        policy = admission_policy!(tenant_id)
        current_active_conversations = active_conversation_count(tenant_id)

        quota_ok!(
          AdmissionQuotas.check_conversation_creation(
            policy,
            current_active_conversations,
            length(member_ids)
          )
        )

        conversation =
          %Conversation{}
          |> Conversation.changeset(%{
            tenant_id: tenant_id,
            created_by_user_id: user_id,
            kind: kind,
            title: title,
            visibility: visibility,
            direct_key: direct_key,
            next_sequence: 1
          })
          |> insert_or_rollback()

        Enum.each(member_ids, fn member_id ->
          role = if member_id == user_id, do: :owner, else: :member

          %Membership{}
          |> Membership.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation.id,
            user_id: member_id,
            role: role,
            joined_at: now,
            last_read_sequence: 0
          })
          |> insert_or_rollback()
        end)

        insert_event(conversation, "conversation.created.v1", subject, %{
          kind: kind,
          title: conversation.title,
          member_ids: member_ids
        })

        conversation
      end)
    end
  rescue
    error in Ecto.ConstraintError -> {:error, constraint_reason(error)}
  end

  def list_for_user(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    unavailable_conversations = AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

    from(c in Conversation,
      join: m in Membership,
      on: m.conversation_id == c.id,
      where:
        c.tenant_id == ^tenant_id and m.tenant_id == ^tenant_id and m.user_id == ^user_id and
          is_nil(m.left_at) and is_nil(c.archived_at) and
          c.id not in subquery(unavailable_conversations),
      order_by: [desc: c.updated_at],
      select: %{
        conversation: c,
        membership_role: m.role,
        last_read_sequence: m.last_read_sequence,
        unread_count: fragment("GREATEST((? - 1) - ?, 0)", c.next_sequence, m.last_read_sequence)
      }
    )
    |> Repo.all()
  end

  def discover_public_channels(params, subject) when is_map(params) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    with :ok <- authorize_discovery(subject),
         {:ok, cursor} <- optional_channel_cursor(value(params, :cursor)),
         {:ok, search} <- normalize_channel_search(value(params, :q)) do
      limit = parse_channel_limit(value(params, :limit))

      active_members =
        from(m in Membership,
          where: m.tenant_id == ^tenant_id and is_nil(m.left_at),
          group_by: m.conversation_id,
          select: %{conversation_id: m.conversation_id, member_count: count(m.id)}
        )

      results =
        from(c in Conversation,
          left_join: membership in Membership,
          on:
            membership.conversation_id == c.id and membership.tenant_id == ^tenant_id and
              membership.user_id == ^user_id and is_nil(membership.left_at),
          left_join: members in subquery(active_members),
          on: members.conversation_id == c.id,
          where:
            c.tenant_id == ^tenant_id and c.kind == :channel and c.visibility == :tenant and
              is_nil(c.archived_at),
          order_by: [desc: c.inserted_at, desc: c.id],
          select: %{
            conversation: c,
            membership: membership,
            joined: not is_nil(membership.id),
            member_count: fragment("COALESCE(?, 0)", members.member_count)
          }
        )
        |> maybe_search_channels(search)
        |> maybe_before_channel_cursor(cursor)
        |> limit(^(limit + 1))
        |> Repo.all()

      has_more = length(results) > limit
      channels = Enum.take(results, limit)

      {:ok,
       %{
         channels: channels,
         limit: limit,
         has_more: has_more,
         next_cursor: if(has_more, do: channel_cursor_for(List.last(channels)), else: nil)
       }}
    end
  end

  def join_public_channel(id, subject) when is_binary(id) and is_map(subject) do
    with :ok <- authorize_join(id, subject) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, subject, require_enabled: true)
        authorize_in_transaction!(fn -> authorize_join(conversation.id, subject) end)
        policy = admission_policy!(conversation.tenant_id)

        user_id = value(subject, :user_id)
        timestamp = now()

        {membership, replayed} =
          case lock_membership(conversation, user_id) do
            nil ->
              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

              membership =
                %Membership{}
                |> Membership.changeset(%{
                  tenant_id: conversation.tenant_id,
                  conversation_id: conversation.id,
                  user_id: user_id,
                  role: :member,
                  joined_at: timestamp,
                  left_at: nil,
                  last_read_sequence: 0
                })
                |> insert_or_rollback()

              {membership, false}

            %Membership{left_at: nil} = membership ->
              {membership, true}

            %Membership{} = membership ->
              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

              rejoined =
                membership
                |> Membership.changeset(%{
                  role: :member,
                  joined_at: timestamp,
                  left_at: nil
                })
                |> Ecto.Changeset.optimistic_lock(:lock_version)
                |> update_or_rollback()

              {rejoined, false}
          end

        unless replayed do
          insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: membership.user_id,
            action: "added",
            role: membership.role,
            membership_version: membership.lock_version,
            source: "self_service"
          })
        end

        %{conversation: conversation, membership: membership, replayed: replayed}
      end)
      |> transaction_result()
    end
  end

  def leave_public_channel(id, attrs, subject)
      when is_binary(id) and is_map(attrs) and is_map(subject) do
    with :ok <- authorize_leave(id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, subject, require_enabled: false)
        authorize_in_transaction!(fn -> authorize_leave(conversation.id, subject) end)
        lock_memberships!(conversation.id, conversation.tenant_id)

        membership =
          Repo.get_by(Membership,
            tenant_id: conversation.tenant_id,
            conversation_id: conversation.id,
            user_id: value(subject, :user_id)
          ) || Repo.rollback(:not_found)

        if membership.left_at do
          %{conversation: conversation, membership: membership, replayed: true}
        else
          if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)
          ensure_conversation_owner_remains!(membership)

          left_membership =
            membership
            |> Membership.changeset(%{left_at: now()})
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()

          insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: left_membership.user_id,
            action: "removed",
            role: left_membership.role,
            membership_version: left_membership.lock_version,
            source: "self_service"
          })

          CallLifecycleCommand.membership_revoked(
            conversation.tenant_id,
            conversation.id,
            left_membership.user_id,
            "membership_left"
          )
          |> CallLifecyclePort.revoke_conversation_access()
          |> call_lifecycle_ok!()

          %{conversation: conversation, membership: left_membership, replayed: false}
        end
      end)
      |> transaction_result()
    end
  end

  def get_for_user(id, subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    query =
      from(c in Conversation,
        join: m in Membership,
        on: m.conversation_id == c.id,
        where:
          c.id == ^id and c.tenant_id == ^tenant_id and m.tenant_id == ^tenant_id and
            m.user_id == ^user_id and is_nil(m.left_at),
        select: %{
          conversation: c,
          membership_role: m.role,
          last_read_sequence: m.last_read_sequence,
          unread_count:
            fragment("GREATEST((? - 1) - ?, 0)", c.next_sequence, m.last_read_sequence)
        }
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      result -> {:ok, result}
    end
  end

  def update(id, attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage(id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation =
          Repo.one(
            from(c in Conversation,
              where:
                c.id == ^id and c.tenant_id == ^value(subject, :tenant_id) and
                  is_nil(c.archived_at),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if conversation.lock_version != expected_version, do: Repo.rollback(:stale_version)

        changes =
          %{}
          |> maybe_put(:title, value(attrs, :title))
          |> maybe_put(:visibility, normalized_visibility(value(attrs, :visibility)))
          |> enforce_direct_fields(conversation)

        requested_visibility = Map.get(changes, :visibility, conversation.visibility)

        case validate_public_channel(subject, conversation.kind, requested_visibility) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        updated =
          conversation
          |> Conversation.changeset(changes)
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(updated, "conversation.updated.v1", subject, %{
          before: %{title: conversation.title, visibility: conversation.visibility},
          after: %{title: updated.title, visibility: updated.visibility},
          version: updated.lock_version
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def archive(id, attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage(id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation =
          Repo.one(
            from(c in Conversation,
              where: c.id == ^id and c.tenant_id == ^value(subject, :tenant_id),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if conversation.lock_version != expected_version, do: Repo.rollback(:stale_version)
        if conversation.archived_at, do: Repo.rollback(:conversation_archived)

        archived =
          conversation
          |> Conversation.changeset(%{archived_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(archived, "conversation.archived.v1", subject, %{
          version: archived.lock_version
        })

        CallLifecycleCommand.conversation_archived(
          archived.tenant_id,
          archived.id,
          "conversation_archived"
        )
        |> CallLifecyclePort.revoke_conversation_access()
        |> call_lifecycle_ok!()

        archived
      end)
      |> transaction_result()
    end
  end

  def list_members(conversation_id, subject) do
    with :ok <- authorize_read(conversation_id, subject) do
      tenant_id = value(subject, :tenant_id)

      memberships =
        Repo.all(
          from(membership in Membership,
            where:
              membership.conversation_id == ^conversation_id and
                membership.tenant_id == ^tenant_id and is_nil(membership.left_at)
          )
        )

      memberships_by_user_id = Map.new(memberships, &{&1.user_id, &1})

      members =
        tenant_id
        |> Accounts.resolve_user_views(Map.keys(memberships_by_user_id))
        |> Enum.map(fn user ->
          %{membership: Map.fetch!(memberships_by_user_id, user.id), user: user}
        end)

      {:ok, members}
    end
  end

  @doc """
  Returns the active member user IDs for a tenant-scoped conversation.

  Results are scalar IDs ordered deterministically; membership persistence
  details remain internal to Conversations.
  """
  @spec active_member_ids(Ecto.UUID.t(), Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def active_member_ids(tenant_id, conversation_id)
      when is_binary(tenant_id) and is_binary(conversation_id) do
    Repo.all(
      from(m in Membership,
        where:
          m.tenant_id == ^tenant_id and m.conversation_id == ^conversation_id and
            is_nil(m.left_at),
        order_by: [asc: m.user_id],
        select: m.user_id
      )
    )
  end

  def add_member(conversation_id, user_id, role, subject) do
    with :ok <- authorize_manage(conversation_id, subject),
         {:ok, assigned_role} <- membership_role(role) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(fn -> authorize_manage(conversation.id, subject) end)
        policy = admission_policy!(conversation.tenant_id)

        unless Accounts.resolve_active_user_ids(conversation.tenant_id, [user_id]) == [user_id],
          do: Repo.rollback(:invalid_member)

        timestamp = now()

        {membership, changed?} =
          case Repo.one(
                 from(m in Membership,
                   where:
                     m.conversation_id == ^conversation_id and m.user_id == ^user_id and
                       m.tenant_id == ^conversation.tenant_id,
                   lock: "FOR UPDATE"
                 )
               ) do
            nil ->
              authorize_ownership_change!(nil, assigned_role, subject, conversation)

              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

              %Membership{}
              |> Membership.changeset(%{
                tenant_id: conversation.tenant_id,
                conversation_id: conversation_id,
                user_id: user_id,
                role: assigned_role,
                joined_at: timestamp,
                left_at: nil,
                last_read_sequence: 0
              })
              |> insert_or_rollback()
              |> then(&{&1, true})

            %Membership{left_at: nil} = membership ->
              authorize_ownership_change!(
                membership.role,
                assigned_role,
                subject,
                conversation
              )

              if membership.role == assigned_role do
                {membership, false}
              else
                Repo.rollback(:version_required)
              end

            membership ->
              authorize_ownership_change!(nil, assigned_role, subject, conversation)

              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

              membership
              |> Membership.changeset(%{
                role: assigned_role,
                joined_at: timestamp,
                left_at: nil
              })
              |> Ecto.Changeset.optimistic_lock(:lock_version)
              |> update_or_rollback()
              |> then(&{&1, true})
          end

        if changed? do
          insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: user_id,
            action: "added",
            role: assigned_role
          })
        end

        membership
      end)
    else
      {:error, _} = error -> error
    end
  end

  def remove_member(conversation_id, user_id, attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage(conversation_id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(fn -> authorize_manage(conversation.id, subject) end)
        lock_memberships!(conversation_id, conversation.tenant_id)

        membership =
          Repo.get_by(Membership,
            conversation_id: conversation_id,
            user_id: user_id,
            tenant_id: conversation.tenant_id
          ) || Repo.rollback(:not_found)

        if membership.left_at, do: Repo.rollback(:not_found)
        authorize_ownership_change!(membership.role, nil, subject, conversation)
        if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)
        ensure_conversation_owner_remains!(membership)

        updated =
          membership
          |> Membership.changeset(%{left_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(conversation, "membership.changed.v1", subject, %{
          user_id: user_id,
          action: "removed",
          role: membership.role
        })

        CallLifecycleCommand.membership_revoked(
          conversation.tenant_id,
          conversation.id,
          updated.user_id,
          "membership_removed"
        )
        |> CallLifecyclePort.revoke_conversation_access()
        |> call_lifecycle_ok!()

        updated
      end)
      |> transaction_result()
    end
  end

  def change_member_role(conversation_id, user_id, attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage(conversation_id, subject),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, role} <- membership_role(value(attrs, :role)) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(fn -> authorize_manage(conversation.id, subject) end)

        lock_memberships!(conversation_id, conversation.tenant_id)

        membership =
          Repo.one(
            from(m in Membership,
              where:
                m.conversation_id == ^conversation_id and m.user_id == ^user_id and
                  m.tenant_id == ^conversation.tenant_id and is_nil(m.left_at)
            )
          ) || Repo.rollback(:not_found)

        authorize_ownership_change!(membership.role, role, subject, conversation)
        if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)

        if membership.role == :owner and role != :owner,
          do: ensure_conversation_owner_remains!(membership)

        updated =
          membership
          |> Membership.changeset(%{role: role})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(conversation, "membership.role_changed.v1", subject, %{
          user_id: user_id,
          before_role: membership.role,
          role: updated.role,
          version: updated.lock_version
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def mark_read(conversation_id, sequence, subject) when is_integer(sequence) do
    with :ok <- authorize_mark_read(conversation_id, subject),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: value(subject, :tenant_id)
           ) do
      target = sequence |> max(0) |> min(max(conversation.next_sequence - 1, 0))
      now = now()

      query =
        from(m in Membership,
          where:
            m.conversation_id == ^conversation_id and
              m.user_id == ^value(subject, :user_id) and
              m.tenant_id == ^value(subject, :tenant_id) and is_nil(m.left_at)
        )

      update_query =
        from(m in query,
          update: [
            set: [
              last_read_sequence: fragment("GREATEST(?, ?)", m.last_read_sequence, ^target),
              updated_at: ^now
            ]
          ]
        )

      case Repo.update_all(update_query, []) do
        {1, _} -> {:ok, target}
        _ -> {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def mark_read(_, _, _), do: {:error, :invalid_sequence}

  defp insert_event(conversation, type, subject, payload) do
    now = now()

    Outbox.insert_and_enqueue!(%{
      tenant_id: conversation.tenant_id,
      event_type: type,
      aggregate_type: "conversation",
      aggregate_id: conversation.id,
      payload: Map.put(payload, :conversation_id, conversation.id),
      available_at: now
    })

    Audit.record(%{
      tenant_id: conversation.tenant_id,
      actor_user_id: value(subject, :user_id),
      action: String.replace(type, ".v1", ""),
      resource_type: "conversation",
      resource_id: conversation.id,
      metadata: payload,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp validate_members(tenant_id, member_ids) do
    active_user_ids = Accounts.resolve_active_user_ids(tenant_id, member_ids)

    if MapSet.new(active_user_ids) == MapSet.new(member_ids),
      do: :ok,
      else: {:error, :invalid_members}
  end

  defp direct_key(:direct, member_ids) when length(member_ids) == 2 do
    {:ok, member_ids |> Enum.sort() |> Enum.join(":")}
  end

  defp direct_key(:direct, _), do: {:error, :direct_conversation_requires_two_members}
  defp direct_key(_, _), do: {:ok, nil}

  defp normalize_member_ids(ids, owner_id) do
    ids = if is_list(ids), do: ids, else: []
    [owner_id | ids] |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  defp lock_direct_access!(subject, expected_grant) do
    case Accounts.lock_access_grant(subject) do
      {:ok, locked_grant}
      when locked_grant.tenant_id == expected_grant.tenant_id and
             locked_grant.user_id == expected_grant.user_id ->
        locked_grant

      _ ->
        Repo.rollback(:forbidden)
    end
  end

  defp lock_directory_members!(tenant_id, member_ids) do
    case Accounts.lock_active_human_directory_users(tenant_id, member_ids) do
      {:ok, people} when length(people) == 2 -> :ok
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_direct_conversation(tenant_id, direct_key) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.tenant_id == ^tenant_id and conversation.kind == :direct and
            conversation.direct_key == ^direct_key,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_active_direct_memberships!(conversation, member_ids) do
    active_member_ids =
      Repo.all(
        from(membership in Membership,
          where:
            membership.tenant_id == ^conversation.tenant_id and
              membership.conversation_id == ^conversation.id and
              membership.user_id in ^member_ids and is_nil(membership.left_at),
          order_by: [asc: membership.user_id],
          select: membership.user_id,
          lock: "FOR SHARE"
        )
      )

    if active_member_ids != member_ids, do: Repo.rollback(:direct_conversation_unavailable)
  end

  defp create_direct_conversation!(
         tenant_id,
         actor_user_id,
         member_ids,
         direct_key,
         subject
       ) do
    timestamp = now()

    conversation =
      %Conversation{}
      |> Conversation.changeset(%{
        tenant_id: tenant_id,
        created_by_user_id: actor_user_id,
        kind: :direct,
        visibility: :private,
        direct_key: direct_key,
        next_sequence: 1
      })
      |> insert_or_rollback()

    Enum.each(member_ids, fn member_id ->
      role = if member_id == actor_user_id, do: :owner, else: :member

      %Membership{}
      |> Membership.changeset(%{
        tenant_id: tenant_id,
        conversation_id: conversation.id,
        user_id: member_id,
        role: role,
        joined_at: timestamp,
        last_read_sequence: 0
      })
      |> insert_or_rollback()
    end)

    insert_event(conversation, "conversation.created.v1", subject, %{
      kind: :direct,
      title: nil,
      member_ids: member_ids
    })

    conversation
  end

  defp normalize_channel_search(nil), do: {:ok, nil}

  defp normalize_channel_search(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      String.length(value) <= 160 -> {:ok, value}
      true -> {:error, :invalid_search_query}
    end
  end

  defp normalize_channel_search(_), do: {:error, :invalid_search_query}

  defp maybe_search_channels(query, nil), do: query

  defp maybe_search_channels(query, search) do
    where(
      query,
      [conversation, ...],
      fragment("strpos(lower(coalesce(?, '')), lower(?)) > 0", conversation.title, ^search)
    )
  end

  defp optional_channel_cursor(nil), do: {:ok, nil}
  defp optional_channel_cursor(""), do: {:ok, nil}

  defp optional_channel_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"inserted_at" => inserted_at, "id" => id}} <- Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(inserted_at),
         {:ok, _uuid} <- Ecto.UUID.cast(id) do
      {:ok, {timestamp, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_channel_cursor(_), do: {:error, :invalid_cursor}

  defp maybe_before_channel_cursor(query, nil), do: query

  defp maybe_before_channel_cursor(query, {timestamp, id}) do
    where(
      query,
      [conversation, ...],
      conversation.inserted_at < ^timestamp or
        (conversation.inserted_at == ^timestamp and conversation.id < ^id)
    )
  end

  defp channel_cursor_for(nil), do: nil

  defp channel_cursor_for(%{conversation: conversation}) do
    %{inserted_at: DateTime.to_iso8601(conversation.inserted_at), id: conversation.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp parse_channel_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_channel_limit)

  defp parse_channel_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_channel_limit(number)
      _ -> @default_channel_limit
    end
  end

  defp parse_channel_limit(_), do: @default_channel_limit

  defp authorize_public_channel(action, conversation_id, subject)
       when action in [:join, :leave] and is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         :ok <- require_workspace_for_public_join(action, grant),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil} <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: grant.tenant_id
           ),
         :ok <- maybe_require_public_channels_enabled(action, subject) do
      :ok
    else
      {:error, :public_channels_disabled} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_public_channel(_action, _conversation_id, _subject),
    do: {:error, :forbidden}

  defp authorize_active_membership(conversation_id, subject)
       when is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         %Membership{} <- active_membership(grant, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_active_membership(_conversation_id, _subject),
    do: {:error, :forbidden}

  defp authorize_management(action, conversation_id, subject)
       when action in [:manage_conversation, :manage_conversation_ownership] and
              is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject) do
      authorization =
        with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
             %Conversation{} = conversation <-
               Repo.get_by(Conversation,
                 id: conversation_id,
                 tenant_id: grant.tenant_id
               ) do
          membership = active_membership(grant, conversation_id)

          case {action, grant.role, membership, conversation} do
            {:manage_conversation, _tenant_role, %Membership{role: role}, _conversation}
            when role in [:owner, :moderator] ->
              :ok

            {:manage_conversation_ownership, _tenant_role, %Membership{role: :owner},
             _conversation} ->
              :ok

            {_action, role, _membership, %Conversation{kind: :channel, visibility: :tenant}}
            when role in [:owner, :admin] ->
              :ok

            _ ->
              {:error, :forbidden}
          end
        else
          _ -> {:error, :forbidden}
        end

      case authorization do
        :ok -> :ok
        {:error, :forbidden} -> deny_conversation_management(action, grant, subject)
      end
    else
      {:error, _reason} ->
        Accounts.audit_authorization_denial(action, subject, :forbidden)
    end
  end

  defp authorize_management(_action, _conversation_id, _subject),
    do: {:error, :forbidden}

  defp active_membership(grant, conversation_id) do
    unavailable_conversations = AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

    Repo.one(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.conversation_id == ^conversation_id and
            membership.user_id == ^grant.user_id and
            membership.tenant_id == ^grant.tenant_id and
            conversation.tenant_id == ^grant.tenant_id and
            is_nil(membership.left_at) and is_nil(conversation.archived_at) and
            conversation.id not in subquery(unavailable_conversations)
      )
    )
  end

  defp maybe_require_public_channels_enabled(:join, subject),
    do: public_channels_enabled(subject)

  defp maybe_require_public_channels_enabled(:leave, _subject), do: :ok

  defp require_workspace_for_public_join(:join, %{account_type: :human, access_scope: :workspace}),
    do: :ok

  defp require_workspace_for_public_join(:leave, _grant), do: :ok
  defp require_workspace_for_public_join(_action, _grant), do: {:error, :forbidden}

  defp public_channels_enabled(subject) do
    case Administration.member_capabilities(subject) do
      {:ok, %{allow_public_channels: false}} -> {:error, :public_channels_disabled}
      {:ok, %{allow_public_channels: true}} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp deny_conversation_management(action, _grant, subject),
    do: Accounts.audit_authorization_denial(action, subject, :forbidden)

  defp lock_channel!(conversation_id, subject) do
    Repo.one(
      from(c in Conversation,
        where: c.id == ^conversation_id and c.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_membership(conversation, user_id) do
    Repo.one(
      from(m in Membership,
        where:
          m.tenant_id == ^conversation.tenant_id and
            m.conversation_id == ^conversation.id and m.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_public_channel!(
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil},
         subject,
         require_enabled: require_enabled
       ) do
    if require_enabled do
      case validate_public_channel(subject, :channel, :tenant) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      :ok
    end
  end

  defp ensure_public_channel!(%Conversation{archived_at: archived_at}, _subject, _opts)
       when not is_nil(archived_at),
       do: Repo.rollback(:conversation_archived)

  defp ensure_public_channel!(_conversation, _subject, _opts), do: Repo.rollback(:forbidden)

  defp lock_memberships!(conversation_id, tenant_id) do
    Repo.all(
      from(m in Membership,
        where: m.conversation_id == ^conversation_id and m.tenant_id == ^tenant_id,
        select: m.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_conversation!(conversation_id, subject) do
    Repo.one(
      from(c in Conversation,
        where:
          c.id == ^conversation_id and c.tenant_id == ^value(subject, :tenant_id) and
            is_nil(c.archived_at),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp reject_direct_membership_change!(%Conversation{kind: :direct}),
    do: Repo.rollback(:direct_membership_immutable)

  defp reject_direct_membership_change!(_conversation), do: :ok

  defp authorize_in_transaction!(authorization) when is_function(authorization, 0) do
    case authorization.() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_ownership_change!(current_role, requested_role, subject, conversation)
       when current_role == :owner or requested_role == :owner do
    authorize_in_transaction!(fn -> authorize_manage_ownership(conversation.id, subject) end)
  end

  defp authorize_ownership_change!(_current_role, _requested_role, _subject, _conversation),
    do: :ok

  defp ensure_conversation_owner_remains!(%Membership{role: :owner} = membership) do
    remaining =
      Membership
      |> where(
        [m],
        m.tenant_id == ^membership.tenant_id and
          m.conversation_id == ^membership.conversation_id and m.id != ^membership.id and
          m.role == :owner and is_nil(m.left_at)
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: Repo.rollback(:cannot_remove_owner)
  end

  defp ensure_conversation_owner_remains!(_), do: :ok

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

  defp membership_role(value) do
    case enum_value(value, [:member, :moderator, :owner], nil) do
      nil -> {:error, :invalid_role}
      role -> {:ok, role}
    end
  end

  defp validate_public_channel(subject, :channel, :tenant),
    do: public_channels_enabled(subject)

  defp validate_public_channel(_subject, _kind, _visibility), do: :ok

  defp normalized_visibility(nil), do: nil

  defp normalized_visibility(value),
    do: enum_value(value, [:private, :tenant], :invalid_visibility)

  defp enforce_direct_fields(attrs, %Conversation{kind: :direct}) do
    attrs
    |> Map.put(:title, nil)
    |> Map.put(:visibility, :private)
  end

  defp enforce_direct_fields(attrs, _), do: attrs

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp project_direct_conversation_result({:ok, result}, subject) do
    {:ok,
     %{
       result
       | conversation: project_authorized_conversation(result.conversation, subject)
     }}
  end

  defp project_direct_conversation_result({:error, _reason} = error, _subject), do: error

  defp project_authorized_user_conversation(result, subject) do
    counterparts = direct_counterparts([result], subject)

    CommsCore.Conversations.Projector.user_conversation(
      result,
      Map.get(counterparts, result.conversation.id)
    )
  end

  defp project_authorized_conversation(%Conversation{} = conversation, subject) do
    counterparts = direct_counterparts([%{conversation: conversation}], subject)

    CommsCore.Conversations.Projector.conversation(
      conversation,
      Map.get(counterparts, conversation.id)
    )
  end

  defp direct_counterparts(results, subject) do
    case Accounts.access_grant(subject) do
      {:ok, grant} -> direct_counterparts_for_grant(results, grant)
      _ -> %{}
    end
  end

  defp direct_counterparts_for_grant(results, grant) do
    tenant_id = grant.tenant_id
    user_id = grant.user_id

    direct_ids =
      results
      |> Enum.flat_map(fn
        %{conversation: %Conversation{tenant_id: ^tenant_id, kind: :direct, id: id}} -> [id]
        _ -> []
      end)
      |> Enum.uniq()

    counterpart_memberships =
      if direct_ids == [] do
        []
      else
        Repo.all(
          from(membership in Membership,
            where:
              membership.tenant_id == ^tenant_id and
                membership.conversation_id in ^direct_ids and membership.user_id != ^user_id and
                is_nil(membership.left_at),
            order_by: [asc: membership.conversation_id, asc: membership.user_id],
            select: %{
              conversation_id: membership.conversation_id,
              user_id: membership.user_id
            }
          )
        )
      end

    counterpart_users =
      tenant_id
      |> Accounts.resolve_user_views(Enum.map(counterpart_memberships, & &1.user_id))
      |> Map.new(&{&1.id, &1})

    Map.new(counterpart_memberships, fn membership ->
      counterpart =
        case Map.get(counterpart_users, membership.user_id) do
          %{id: id, display_name: display_name} ->
            %{user_id: id, display_name: display_name}

          nil ->
            nil
        end

      {membership.conversation_id, counterpart}
    end)
  end

  defp project_membership_change(result) do
    %{
      conversation: CommsCore.Conversations.Projector.conversation(result.conversation),
      membership: CommsCore.Conversations.Projector.membership(result.membership),
      replayed: result.replayed
    }
  end

  defp call_lifecycle_ok!({:ok, %CallLifecycleReceipt{}}), do: :ok
  defp call_lifecycle_ok!({:error, reason}), do: Repo.rollback(reason)

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

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp admission_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp active_conversation_count(tenant_id) do
    Conversation
    |> where(
      [conversation],
      conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at)
    )
    |> Repo.aggregate(:count)
  end

  defp ensure_conversation_member_capacity(policy, %Conversation{} = conversation) do
    timestamp = now()

    current_active_members =
      Membership
      |> join(:inner, [membership], joined_conversation in Conversation,
        on:
          joined_conversation.id == membership.conversation_id and
            joined_conversation.tenant_id == membership.tenant_id
      )
      |> join(
        :left,
        [membership, _joined_conversation],
        guest_admission in CommsCore.Conversations.GuestAdmission,
        on:
          guest_admission.tenant_id == membership.tenant_id and
            guest_admission.membership_id == membership.id and
            is_nil(guest_admission.converted_at)
      )
      |> where(
        [membership, joined_conversation, guest_admission],
        membership.tenant_id == ^conversation.tenant_id and
          membership.conversation_id == ^conversation.id and
          joined_conversation.tenant_id == ^conversation.tenant_id and
          is_nil(joined_conversation.archived_at) and is_nil(membership.left_at) and
          (is_nil(guest_admission.id) or
             (is_nil(guest_admission.revoked_at) and guest_admission.expires_at > ^timestamp))
      )
      |> Repo.aggregate(:count)

    AdmissionQuotas.check_conversation_member_capacity(policy, current_active_members)
  end

  defp enum_value(value, allowed, default) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: atom, else: default
  rescue
    ArgumentError -> default
  end

  defp enum_value(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp enum_value(_, _, default), do: default

  defp constraint_reason(%Ecto.ConstraintError{constraint: constraint}) do
    if String.contains?(constraint, "direct_key"),
      do: :direct_conversation_exists,
      else: :conflict
  end

  defp active_service_membership?(subject, conversation_id) do
    Repo.exists?(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.tenant_id == ^value(subject, :tenant_id) and
            membership.user_id == ^value(subject, :user_id) and
            membership.conversation_id == ^conversation_id and is_nil(membership.left_at) and
            is_nil(conversation.archived_at)
      )
    )
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
