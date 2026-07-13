defmodule CommsWeb.Presenter do
  alias CommsCore.Accounts
  alias CommsCore.Accounts.{Device, Tenant, User}
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.{Invitation, TenantSettings}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Governance.{DeletionRequest, LegalHold, RetentionPolicy}
  alias CommsCore.Messaging.{Message, Reaction}
  alias CommsCore.Moderation.{ModerationAction, ModerationCase}

  def tenant(%Tenant{} = tenant) do
    %{id: tenant.id, name: tenant.name, slug: tenant.slug, status: tenant.status}
  end

  def user(%User{} = user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: if(user.account_type == :service, do: nil, else: user.email),
      account_type: user.account_type,
      role: user.role,
      status: user.status,
      version: user.lock_version
    }
  end

  def identity_user(%User{} = user) do
    Map.merge(user(user), Accounts.platform_access_for_user(user))
  end

  def admin_user(%User{} = user), do: identity_user(user)

  def device(%Device{} = device) do
    %{
      id: device.id,
      user_id: device.user_id,
      name: device.name,
      platform: device.platform,
      last_seen_at: device.last_seen_at,
      revoked_at: device.revoked_at
    }
  end

  def session(%Session{} = session) do
    platform_access =
      case session.user do
        %User{} = user -> Accounts.platform_access_for_user(user)
        _ -> %{platform_role: nil, platform_role_expires_at: nil}
      end

    Map.merge(
      %{
        id: session.id,
        user_id: session.user_id,
        device_id: session.device_id,
        expires_at: session.expires_at,
        last_used_at: session.last_used_at,
        revoked_at: session.revoked_at,
        inserted_at: session.inserted_at
      },
      platform_access
    )
  end

  def conversation(%{conversation: %Conversation{} = conversation} = result) do
    conversation(conversation)
    |> Map.merge(%{
      membership_role: result.membership_role,
      last_read_sequence: result.last_read_sequence,
      unread_count: result.unread_count
    })
  end

  def conversation(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      kind: conversation.kind,
      title: conversation.title,
      visibility: conversation.visibility,
      latest_sequence: max(conversation.next_sequence - 1, 0),
      archived_at: conversation.archived_at,
      version: conversation.lock_version,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  def public_channel(
        %{
          conversation: %Conversation{} = conversation,
          joined: joined,
          member_count: member_count
        } = result
      ) do
    conversation(conversation)
    |> Map.merge(%{
      joined: joined,
      member_count: member_count,
      membership: membership(Map.get(result, :membership))
    })
  end

  def membership(%{membership: %Membership{} = membership, user: %User{} = user}) do
    %{
      id: membership.id,
      role: membership.role,
      joined_at: membership.joined_at,
      last_read_sequence: membership.last_read_sequence,
      version: membership.lock_version,
      user: user(user)
    }
  end

  def membership(%Membership{} = membership) do
    %{
      id: membership.id,
      role: membership.role,
      joined_at: membership.joined_at,
      left_at: membership.left_at,
      last_read_sequence: membership.last_read_sequence,
      version: membership.lock_version
    }
  end

  def membership(nil), do: nil

  def tenant_settings(%TenantSettings{} = settings) do
    %{
      tenant_id: settings.tenant_id,
      allow_public_channels: settings.allow_public_channels,
      message_edit_window_seconds: settings.message_edit_window_seconds,
      max_attachment_bytes: settings.max_attachment_bytes,
      default_retention_days: settings.default_retention_days,
      max_active_users: settings.max_active_users,
      max_active_conversations: settings.max_active_conversations,
      max_conversation_members: settings.max_conversation_members,
      version: settings.lock_version
    }
  end

  def tenant_usage(usage) when is_map(usage) do
    %{
      active_users: usage.active_users,
      active_conversations: usage.active_conversations,
      largest_conversation_members: usage.largest_conversation_members,
      limits: usage.limits,
      at_capacity: usage.at_capacity,
      over_limit: usage.over_limit
    }
  end

  def invitation(%Invitation{} = invitation) do
    %{
      id: invitation.id,
      email: invitation.email,
      role: invitation.role,
      status: invitation.status,
      invited_by_user_id: invitation.invited_by_user_id,
      accepted_user_id: invitation.accepted_user_id,
      expires_at: invitation.expires_at,
      accepted_at: invitation.accepted_at,
      revoked_at: invitation.revoked_at,
      version: invitation.lock_version,
      inserted_at: invitation.inserted_at
    }
  end

  def audit_event(%AuditEvent{} = event) do
    %{
      id: event.id,
      actor_user_id: event.actor_user_id,
      action: event.action,
      resource_type: event.resource_type,
      resource_id: event.resource_id,
      metadata: event.metadata,
      request_id: event.request_id,
      inserted_at: event.inserted_at
    }
  end

  def moderation_case(%ModerationCase{} = moderation_case) do
    %{
      id: moderation_case.id,
      reporter_user_id: moderation_case.reporter_user_id,
      subject_user_id: moderation_case.subject_user_id,
      conversation_id: moderation_case.conversation_id,
      message_id: moderation_case.message_id,
      assigned_to_user_id: moderation_case.assigned_to_user_id,
      category: moderation_case.category,
      summary: moderation_case.summary,
      details: moderation_case.details,
      priority: moderation_case.priority,
      status: moderation_case.status,
      resolved_at: moderation_case.resolved_at,
      version: moderation_case.lock_version,
      inserted_at: moderation_case.inserted_at,
      updated_at: moderation_case.updated_at
    }
  end

  def moderation_action(%ModerationAction{} = action) do
    %{
      id: action.id,
      moderation_case_id: action.moderation_case_id,
      actor_user_id: action.actor_user_id,
      action_type: action.action_type,
      note: action.note,
      metadata: action.metadata,
      inserted_at: action.inserted_at
    }
  end

  def retention_policy(%RetentionPolicy{} = policy) do
    %{
      id: policy.id,
      conversation_id: policy.conversation_id,
      name: policy.name,
      scope_type: policy.scope_type,
      retention_days: policy.retention_days,
      delete_attachments: policy.delete_attachments,
      status: policy.status,
      version: policy.lock_version,
      inserted_at: policy.inserted_at,
      updated_at: policy.updated_at
    }
  end

  def legal_hold(%LegalHold{} = hold) do
    %{
      id: hold.id,
      created_by_user_id: hold.created_by_user_id,
      subject_user_id: hold.subject_user_id,
      conversation_id: hold.conversation_id,
      name: hold.name,
      reason: hold.reason,
      scope_type: hold.scope_type,
      status: hold.status,
      starts_at: hold.starts_at,
      released_at: hold.released_at,
      version: hold.lock_version,
      inserted_at: hold.inserted_at
    }
  end

  def deletion_request(%DeletionRequest{} = request) do
    %{
      id: request.id,
      requested_by_user_id: request.requested_by_user_id,
      subject_user_id: request.subject_user_id,
      conversation_id: request.conversation_id,
      message_id: request.message_id,
      target_type: request.target_type,
      reason: request.reason,
      status: request.status,
      scheduled_for: request.scheduled_for,
      completed_at: request.completed_at,
      execution_started_at: request.execution_started_at,
      execution_attempts: request.execution_attempts,
      execution_error: request.execution_error,
      evidence: request.evidence,
      version: request.lock_version,
      inserted_at: request.inserted_at,
      updated_at: request.updated_at
    }
  end

  def message(%Message{} = message) do
    %{
      id: message.id,
      tenant_id: message.tenant_id,
      conversation_id: message.conversation_id,
      sender_user_id: message.sender_user_id,
      sender_device_id: message.sender_device_id,
      reply_to_message_id: message.reply_to_message_id,
      thread_root_message_id: message.thread_root_message_id,
      thread_reply_count: message.thread_reply_count || 0,
      mentioned_user_ids: mention_user_ids(message.mentions),
      client_message_id: message.client_message_id,
      conversation_sequence: message.conversation_sequence,
      body: message.body,
      metadata: message.metadata || %{},
      status: message.status,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at,
      attachments: association(message.attachments, &attachment/1),
      reactions: association(message.reactions, &reaction/1)
    }
  end

  def attachment(%Attachment{} = attachment) do
    %{
      id: attachment.id,
      message_id: attachment.message_id,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      checksum_sha256: attachment.checksum_sha256,
      status: attachment.status,
      uploaded_at: attachment.uploaded_at,
      scan_status: attachment.scan_status,
      scan_verdict: attachment.scan_verdict,
      scan_provider: attachment.scan_provider,
      scan_attempts: attachment.scan_attempts,
      scan_error_code: attachment.scan_error_code,
      scanned_at: attachment.scanned_at,
      quarantined_at: attachment.quarantined_at
    }
  end

  defp reaction(%Reaction{} = reaction) do
    %{id: reaction.id, user_id: reaction.user_id, emoji: reaction.emoji}
  end

  defp mention_user_ids(%Ecto.Association.NotLoaded{}), do: []

  defp mention_user_ids(mentions) when is_list(mentions) do
    mentions |> Enum.map(& &1.user_id) |> Enum.sort()
  end

  defp mention_user_ids(_mentions), do: []

  defp association(%Ecto.Association.NotLoaded{}, _mapper), do: []
  defp association(values, mapper) when is_list(values), do: Enum.map(values, mapper)
  defp association(_, _mapper), do: []
end
