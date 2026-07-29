defmodule CommsWeb.Presenters.Administration do
  @moduledoc false

  alias CommsCore.Administration.{
    InvitationView,
    TenantSettingsView,
    TenantView
  }

  alias CommsCore.Audit.Event

  def tenant(%TenantView{} = tenant) do
    %{id: tenant.id, name: tenant.name, slug: tenant.slug, status: tenant.status}
  end

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
end
