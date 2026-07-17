defmodule CommsCore.Administration.Projector do
  @moduledoc false

  alias CommsCore.Accounts.Tenant

  alias CommsCore.Administration.{
    Invitation,
    InvitationView,
    TenantSettings,
    TenantSettingsView,
    TenantView
  }

  def tenant(%Tenant{} = tenant),
    do: struct!(TenantView, Map.take(tenant, [:id, :name, :slug, :status]))

  def tenant(%TenantView{} = tenant), do: tenant

  def settings(%TenantSettings{} = settings) do
    struct!(TenantSettingsView, %{
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
      version: settings.lock_version
    })
  end

  def invitation(%Invitation{} = invitation) do
    struct!(InvitationView, %{
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
    })
  end
end
