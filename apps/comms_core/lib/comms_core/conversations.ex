defmodule CommsCore.Conversations do
  alias CommsCore.{Repo, RuntimePorts}

  alias CommsCore.Accounts.{
    ConversationBootstrapPort,
    InitialConversationCommand
  }

  alias CommsCore.Conversations.{
    AccessPolicy,
    AdmissionUsage,
    AdmissionUsageQuery,
    Bootstrap,
    CallAccess,
    CallConversation,
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    CallMembership,
    Commands,
    ContentAccess,
    ConversationView,
    DataLifecycle,
    Directory,
    DirectConversations,
    Memberships,
    MessageWriteSlot,
    PublicChannels,
    ReleaseFingerprint
  }

  @behaviour ConversationBootstrapPort

  @doc false
  def release_tenant_fingerprint_fragment(repo, tenant_id),
    do: ReleaseFingerprint.fragment(repo, tenant_id)

  @impl ConversationBootstrapPort
  def create_initial_channel(%InitialConversationCommand{} = command),
    do: Bootstrap.create_initial_channel(command)

  @impl ConversationBootstrapPort
  def fetch_initial_channel(tenant_id, owner_user_id),
    do: Bootstrap.fetch_initial_channel(tenant_id, owner_user_id)

  def list_for_service(subject), do: Directory.list_for_service(subject)

  def authorize_service_access(subject, required_scope, conversation_id),
    do: AccessPolicy.authorize_service_access(subject, required_scope, conversation_id)

  def authorize_create(subject), do: AccessPolicy.authorize_create(subject)
  def authorize_discovery(subject), do: AccessPolicy.authorize_discovery(subject)

  def authorize_join(conversation_id, subject),
    do: AccessPolicy.authorize_join(conversation_id, subject)

  def authorize_leave(conversation_id, subject),
    do: AccessPolicy.authorize_leave(conversation_id, subject)

  def authorize_read(conversation_id, subject),
    do: AccessPolicy.authorize_read(conversation_id, subject)

  @spec call_membership(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, CallMembership.t()} | {:error, :forbidden}
  def call_membership(tenant_id, conversation_id, user_id),
    do: CallAccess.call_membership(tenant_id, conversation_id, user_id)

  @spec lock_call_conversation(Ecto.UUID.t(), Ecto.UUID.t(), :share | :update) ::
          {:ok, CallConversation.t()} | {:error, :forbidden | :transaction_required}
  def lock_call_conversation(tenant_id, conversation_id, lock_mode),
    do: CallAccess.lock_call_conversation(tenant_id, conversation_id, lock_mode)

  @spec lock_call_membership(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, CallMembership.t()} | {:error, :forbidden | :transaction_required}
  def lock_call_membership(tenant_id, conversation_id, user_id),
    do: CallAccess.lock_call_membership(tenant_id, conversation_id, user_id)

  def authorize_send_message(conversation_id, subject),
    do: AccessPolicy.authorize_send_message(conversation_id, subject)

  def authorize_mark_read(conversation_id, subject),
    do: AccessPolicy.authorize_mark_read(conversation_id, subject)

  def authorize_react_message(conversation_id, subject),
    do: AccessPolicy.authorize_react_message(conversation_id, subject)

  def authorize_upload_attachment(conversation_id, subject),
    do: AccessPolicy.authorize_upload_attachment(conversation_id, subject)

  def authorize_use_whiteboard(conversation_id, subject),
    do: AccessPolicy.authorize_use_whiteboard(conversation_id, subject)

  def authorize_manage(conversation_id, subject),
    do: AccessPolicy.authorize_manage(conversation_id, subject)

  def authorize_manage_ownership(conversation_id, subject),
    do: AccessPolicy.authorize_manage_ownership(conversation_id, subject)

  def create_guest_link_view(conversation_id, attrs, subject),
    do: CommsCore.Conversations.GuestAccess.create_link(conversation_id, attrs, subject)

  def list_guest_link_views(conversation_id, subject),
    do: CommsCore.Conversations.GuestAccess.list_links(conversation_id, subject)

  def revoke_guest_link_view(conversation_id, link_id, subject),
    do:
      CommsCore.Conversations.GuestAccess.revoke_link(
        conversation_id,
        link_id,
        subject,
        &revoke_guest_membership_call_access/4
      )

  def preview_guest_link(token),
    do: CommsCore.Conversations.GuestAccess.preview_link(token)

  def redeem_guest_link(token, attrs),
    do: CommsCore.Conversations.GuestAccess.redeem_link(token, attrs)

  def resolve_guest_access(subject, conversation_id),
    do: CommsCore.Conversations.GuestAccess.resolve_access(subject, conversation_id)

  def guest_scope_for_session(session_id),
    do: CommsCore.Conversations.GuestAccess.scope_for_session(session_id)

  def convert_guest_account(attrs, guest_subject),
    do: CommsCore.Conversations.GuestAccess.convert_account(attrs, guest_subject)

  def logout_guest_session(guest_subject),
    do:
      CommsCore.Conversations.GuestAccess.logout_session(
        guest_subject,
        &revoke_guest_membership_call_access/4
      )

  def create_ephemeral_room(attrs, creator),
    do: CommsCore.Conversations.EphemeralRooms.create(attrs, creator)

  def preview_ephemeral_room(token),
    do: CommsCore.Conversations.EphemeralRooms.preview(token)

  def join_ephemeral_room(token, attrs, joiner),
    do: CommsCore.Conversations.EphemeralRooms.join(token, attrs, joiner)

  def open_ephemeral_presence(attrs),
    do: CommsCore.Conversations.EphemeralRooms.open_presence(attrs)

  def heartbeat_ephemeral_presence(attrs),
    do: CommsCore.Conversations.EphemeralRooms.heartbeat_presence(attrs)

  def close_ephemeral_presence(attrs),
    do: CommsCore.Conversations.EphemeralRooms.close_presence(attrs)

  def ephemeral_room_for_conversation(conversation_id, subject),
    do: CommsCore.Conversations.EphemeralRooms.room_for_conversation(conversation_id, subject)

  @doc false
  def reconcile_ephemeral_room(room_id, expected_generation, caller),
    do:
      CommsCore.Conversations.EphemeralRooms.reconcile(
        room_id,
        expected_generation,
        caller
      )

  @doc false
  def reconcile_ephemeral_rooms(caller),
    do: CommsCore.Conversations.EphemeralRooms.reconcile_all(caller)

  @doc false
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

  @spec admission_usage(Ecto.UUID.t()) :: AdmissionUsage.t()
  def admission_usage(tenant_id), do: AdmissionUsageQuery.get(tenant_id)

  def archive_for_erasure(tenant_id, conversation_id, timestamp),
    do: DataLifecycle.archive_for_erasure(tenant_id, conversation_id, timestamp)

  def remove_user_memberships_for_erasure(tenant_id, user_id, timestamp),
    do: DataLifecycle.remove_user_memberships_for_erasure(tenant_id, user_id, timestamp)

  @spec reserve_message_slot(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MessageWriteSlot.t()}
          | {:error,
             :conversation_not_found | :message_slot_update_failed | :transaction_required}
  def reserve_message_slot(tenant_id, conversation_id),
    do: ContentAccess.reserve_message_slot(tenant_id, conversation_id)

  def validate_active_members(tenant_id, conversation_id, user_ids),
    do: ContentAccess.validate_active_members(tenant_id, conversation_id, user_ids)

  def validate_reference(tenant_id, conversation_id),
    do: DataLifecycle.validate_reference(tenant_id, conversation_id)

  def retention_scope_ids(tenant_id), do: DataLifecycle.retention_scope_ids(tenant_id)

  def active_membership_authorization_query(grant),
    do: AccessPolicy.active_membership_authorization_query(grant)

  def active_conversation_ids(subject), do: AccessPolicy.active_conversation_ids(subject)

  def active_service_membership_authorization_query(subject, required_scope),
    do: AccessPolicy.active_service_membership_authorization_query(subject, required_scope)

  def active_conversation_member?(grant, conversation_id),
    do: AccessPolicy.active_conversation_member?(grant, conversation_id)

  @doc false
  def project(conversation), do: Directory.project(conversation)

  def create_view(attrs, subject), do: Commands.create_view(attrs, subject)
  def list_for_user_views(subject), do: Directory.list_for_user_views(subject)

  def discover_public_channel_views(params, subject),
    do: PublicChannels.discover_views(params, subject)

  def join_public_channel_view(id, subject), do: PublicChannels.join_view(id, subject)

  def leave_public_channel_view(id, attrs, subject),
    do:
      PublicChannels.leave_view(
        id,
        attrs,
        subject,
        &revoke_membership_call_access!/4
      )

  def get_for_user_view(id, subject), do: Directory.get_for_user_view(id, subject)
  def update_view(id, attrs, subject), do: Commands.update_view(id, attrs, subject)

  def archive_view(id, attrs, subject),
    do:
      Commands.archive_view(
        id,
        attrs,
        subject,
        &revoke_conversation_call_access!/3
      )

  def list_member_views(id, subject), do: Directory.list_member_views(id, subject)

  def add_member_view(conversation_id, user_id, role, subject),
    do: Memberships.add_view(conversation_id, user_id, role, subject)

  def remove_member_view(conversation_id, user_id, attrs, subject),
    do:
      Memberships.remove_view(
        conversation_id,
        user_id,
        attrs,
        subject,
        &revoke_membership_call_access!/4
      )

  def change_member_role_view(conversation_id, user_id, attrs, subject),
    do: Memberships.change_role_view(conversation_id, user_id, attrs, subject)

  @spec get_or_create_direct_view(Ecto.UUID.t(), map()) ::
          {:ok, %{conversation: ConversationView.t(), created: boolean()}}
          | {:error,
             :active_conversation_quota_exceeded
             | :conversation_member_quota_exceeded
             | :direct_conversation_unavailable
             | :forbidden
             | :not_found}
  def get_or_create_direct_view(other_user_id, subject),
    do: DirectConversations.get_or_create_view(other_user_id, subject)

  def create(attrs, subject), do: Commands.create(attrs, subject)
  def list_for_user(subject), do: Directory.list_for_user(subject)
  def discover_public_channels(params, subject), do: PublicChannels.discover(params, subject)
  def join_public_channel(id, subject), do: PublicChannels.join(id, subject)

  def leave_public_channel(id, attrs, subject),
    do:
      PublicChannels.leave(
        id,
        attrs,
        subject,
        &revoke_membership_call_access!/4
      )

  def get_for_user(id, subject), do: Directory.get_for_user(id, subject)
  def update(id, attrs, subject), do: Commands.update(id, attrs, subject)

  def archive(id, attrs, subject),
    do:
      Commands.archive(
        id,
        attrs,
        subject,
        &revoke_conversation_call_access!/3
      )

  def list_members(conversation_id, subject), do: Directory.list_members(conversation_id, subject)

  def active_member_ids(tenant_id, conversation_id),
    do: Directory.active_member_ids(tenant_id, conversation_id)

  def add_member(conversation_id, user_id, role, subject),
    do: Memberships.add(conversation_id, user_id, role, subject)

  def remove_member(conversation_id, user_id, attrs, subject),
    do:
      Memberships.remove(
        conversation_id,
        user_id,
        attrs,
        subject,
        &revoke_membership_call_access!/4
      )

  def change_member_role(conversation_id, user_id, attrs, subject),
    do: Memberships.change_role(conversation_id, user_id, attrs, subject)

  def mark_read(conversation_id, sequence, subject),
    do: Commands.mark_read(conversation_id, sequence, subject)

  defp revoke_conversation_call_access!(tenant_id, conversation_id, reason) do
    tenant_id
    |> CallLifecycleCommand.conversation_archived(conversation_id, reason)
    |> CallLifecyclePort.revoke_conversation_access()
    |> call_lifecycle_ok!()
  end

  defp revoke_membership_call_access!(tenant_id, conversation_id, user_id, reason) do
    tenant_id
    |> revoke_guest_membership_call_access(conversation_id, user_id, reason)
    |> call_lifecycle_ok!()
  end

  defp call_lifecycle_ok!({:ok, %CallLifecycleReceipt{}}), do: :ok
  defp call_lifecycle_ok!(:ok), do: :ok
  defp call_lifecycle_ok!({:error, reason}), do: Repo.rollback(reason)
end
