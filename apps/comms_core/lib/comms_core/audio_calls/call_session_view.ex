defmodule CommsCore.AudioCalls.CallSessionView do
  @moduledoc """
  Stable, persistence-free projection for active and recent room sessions.

  The duration is the room-session duration observed when the page was built.
  It is deliberately not a per-user participation duration. Incoming,
  ringing, answered, missed, declined, and scheduled states are not represented
  because the current Calls model does not persist those facts.
  """

  @enforce_keys [
    :id,
    :conversation_id,
    :started_by_user_id,
    :media_kind,
    :status,
    :started_at,
    :expires_at,
    :duration_seconds,
    :can_end
  ]
  defstruct [
    :id,
    :conversation_id,
    :started_by_user_id,
    :ended_by_user_id,
    :media_kind,
    :status,
    :started_at,
    :expires_at,
    :ended_at,
    :end_reason,
    :duration_seconds,
    :can_end
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          started_by_user_id: Ecto.UUID.t(),
          ended_by_user_id: Ecto.UUID.t() | nil,
          media_kind: :audio | :video,
          status: :active | :ending | :ended,
          started_at: DateTime.t(),
          expires_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          end_reason: String.t() | nil,
          duration_seconds: non_neg_integer(),
          can_end: boolean()
        }
end
