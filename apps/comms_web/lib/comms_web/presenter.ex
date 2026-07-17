defmodule CommsWeb.Presenter do
  alias CommsCore.Accounts.{DeviceView, InitialConversationReceipt, SessionView, UserView}
  alias CommsCore.Administration.{InvitationView, TenantSettingsView, TenantView}
  alias CommsCore.Attachments.AttachmentView
  alias CommsCore.AudioCalls.AudioCall
  alias CommsCore.Audit.Event
  alias CommsCore.Conversations.{ConversationView, MembershipView}
  alias CommsCore.Governance.{DeletionRequestView, LegalHoldView, RetentionPolicyView}
  alias CommsCore.Messaging.{MessageView, ReactionView}
  alias CommsCore.Moderation.{ActionView, CaseView}

  def tenant(%TenantView{} = tenant) do
    %{id: tenant.id, name: tenant.name, slug: tenant.slug, status: tenant.status}
  end

  def user(%UserView{} = user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: user.email,
      account_type: user.account_type,
      role: user.role,
      status: user.status,
      version: user.version
    }
  end

  def identity_user(%UserView{} = user) do
    Map.merge(user(user), %{
      platform_role: user.platform_role,
      platform_role_expires_at: user.platform_role_expires_at
    })
  end

  def admin_user(%UserView{} = user), do: identity_user(user)

  def device(%DeviceView{} = device) do
    %{
      id: device.id,
      user_id: device.user_id,
      name: device.name,
      platform: device.platform,
      last_seen_at: device.last_seen_at,
      revoked_at: device.revoked_at
    }
  end

  def session(%SessionView{} = session) do
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
      %{
        platform_role: session.platform_role,
        platform_role_expires_at: session.platform_role_expires_at
      }
    )
  end

  def conversation(%ConversationView{} = conversation) do
    base = %{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      kind: conversation.kind,
      title: conversation.title,
      visibility: conversation.visibility,
      latest_sequence: conversation.latest_sequence,
      archived_at: conversation.archived_at,
      version: conversation.version,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }

    if is_nil(conversation.membership_role) do
      base
    else
      Map.merge(base, %{
        membership_role: conversation.membership_role,
        last_read_sequence: conversation.last_read_sequence,
        unread_count: conversation.unread_count
      })
    end
  end

  def conversation(%InitialConversationReceipt{} = conversation) do
    %{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      kind: conversation.kind,
      title: conversation.title,
      visibility: conversation.visibility,
      latest_sequence: conversation.latest_sequence,
      archived_at: conversation.archived_at,
      version: conversation.version,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  def audio_call(%AudioCall{} = call) do
    %{
      id: call.id,
      tenant_id: call.tenant_id,
      conversation_id: call.conversation_id,
      started_by_user_id: call.started_by_user_id,
      ended_by_user_id: call.ended_by_user_id,
      media_kind: call.media_kind,
      status: call.status,
      started_at: call.started_at,
      expires_at: call.expires_at,
      ended_at: call.ended_at,
      end_reason: call.end_reason,
      version: call.lock_version
    }
  end

  def public_channel(%ConversationView{} = conversation) do
    conversation(conversation)
    |> Map.merge(%{
      joined: conversation.joined,
      member_count: conversation.member_count,
      membership: membership(conversation.membership)
    })
  end

  def membership(%MembershipView{} = membership) do
    %{
      id: membership.id,
      role: membership.role,
      joined_at: membership.joined_at,
      left_at: membership.left_at,
      last_read_sequence: membership.last_read_sequence,
      version: membership.version
    }
    |> maybe_put_user(membership.user)
  end

  def membership(nil), do: nil

  def tenant_settings(%TenantSettingsView{} = settings) do
    %{
      tenant_id: settings.tenant_id,
      allow_public_channels: settings.allow_public_channels,
      allow_audio_calls: settings.allow_audio_calls,
      allow_video_calls: settings.allow_video_calls,
      message_edit_window_seconds: settings.message_edit_window_seconds,
      max_attachment_bytes: settings.max_attachment_bytes,
      default_retention_days: settings.default_retention_days,
      max_active_users: settings.max_active_users,
      max_active_conversations: settings.max_active_conversations,
      max_conversation_members: settings.max_conversation_members,
      version: settings.version
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

  def invitation(%InvitationView{} = invitation) do
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
      version: invitation.version,
      inserted_at: invitation.inserted_at
    }
  end

  def audit_event(%Event{} = event) do
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

  def moderation_case(%CaseView{} = moderation_case) do
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
      version: moderation_case.version,
      inserted_at: moderation_case.inserted_at,
      updated_at: moderation_case.updated_at
    }
  end

  def moderation_action(%ActionView{} = action) do
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

  def retention_policy(%RetentionPolicyView{} = policy) do
    %{
      id: policy.id,
      conversation_id: policy.conversation_id,
      name: policy.name,
      scope_type: policy.scope_type,
      retention_days: policy.retention_days,
      delete_attachments: policy.delete_attachments,
      status: policy.status,
      version: policy.version,
      inserted_at: policy.inserted_at,
      updated_at: policy.updated_at
    }
  end

  def legal_hold(%LegalHoldView{} = hold) do
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
      version: hold.version,
      inserted_at: hold.inserted_at
    }
  end

  def deletion_request(%DeletionRequestView{} = request) do
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
      version: request.version,
      inserted_at: request.inserted_at,
      updated_at: request.updated_at
    }
  end

  def message(%MessageView{} = message) do
    %{
      id: message.id,
      tenant_id: message.tenant_id,
      conversation_id: message.conversation_id,
      sender_user_id: message.sender_user_id,
      sender_device_id: message.sender_device_id,
      reply_to_message_id: message.reply_to_message_id,
      thread_root_message_id: message.thread_root_message_id,
      thread_reply_count: message.thread_reply_count || 0,
      mentioned_user_ids: message.mentioned_user_ids,
      client_message_id: message.client_message_id,
      conversation_sequence: message.conversation_sequence,
      body: message.body,
      metadata: message.metadata || %{},
      status: message.status,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at,
      attachments: Enum.map(message.attachments, &attachment/1),
      reactions: Enum.map(message.reactions, &reaction/1)
    }
  end

  def attachment(%AttachmentView{} = attachment) do
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

  defp reaction(%ReactionView{} = reaction) do
    %{id: reaction.id, user_id: reaction.user_id, emoji: reaction.emoji}
  end

  defp maybe_put_user(map, %UserView{} = user), do: Map.put(map, :user, user(user))
  defp maybe_put_user(map, _), do: map
end
