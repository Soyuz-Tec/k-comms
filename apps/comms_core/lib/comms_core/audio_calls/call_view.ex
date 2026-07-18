defmodule CommsCore.AudioCalls.CallView do
  @moduledoc "Stable, Ecto-free call projection returned to released adapters."

  @enforce_keys [
    :id,
    :tenant_id,
    :conversation_id,
    :started_by_user_id,
    :media_kind,
    :status,
    :started_at,
    :expires_at,
    :version,
    :can_end
  ]
  defstruct [
    :id,
    :tenant_id,
    :conversation_id,
    :started_by_user_id,
    :ended_by_user_id,
    :media_kind,
    :status,
    :started_at,
    :expires_at,
    :ended_at,
    :end_reason,
    :version,
    :can_end
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          conversation_id: String.t(),
          started_by_user_id: String.t(),
          ended_by_user_id: String.t() | nil,
          media_kind: :audio | :video,
          status: :active | :ending | :ended,
          started_at: DateTime.t(),
          expires_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          end_reason: String.t() | nil,
          version: pos_integer(),
          can_end: boolean()
        }
end
