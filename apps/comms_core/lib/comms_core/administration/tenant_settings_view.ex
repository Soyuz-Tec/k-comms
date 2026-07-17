defmodule CommsCore.Administration.TenantSettingsView do
  @moduledoc "Stable tenant policy and quota projection."
  defstruct [
    :tenant_id,
    :allow_public_channels,
    :allow_audio_calls,
    :allow_video_calls,
    :message_edit_window_seconds,
    :max_attachment_bytes,
    :default_retention_days,
    :max_active_users,
    :max_active_conversations,
    :max_conversation_members,
    :version
  ]
end
