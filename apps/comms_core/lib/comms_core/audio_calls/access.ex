defmodule CommsCore.AudioCalls.Access do
  @moduledoc false

  @enforce_keys [
    :tenant_id,
    :user_id,
    :device_id,
    :session_id,
    :conversation_id,
    :membership_role,
    :allow_audio_calls,
    :allow_video_calls
  ]

  defstruct [
    :tenant_id,
    :user_id,
    :device_id,
    :session_id,
    :conversation_id,
    :membership_role,
    :allow_audio_calls,
    :allow_video_calls
  ]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          device_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          membership_role: :member | :moderator | :owner,
          allow_audio_calls: boolean(),
          allow_video_calls: boolean()
        }
end
