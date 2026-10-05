defmodule CommsCore.AudioCalls.CalendarSync.ProtectionQuery do
  @moduledoc "Calls-owned calendar governance seal; acquired before identity locks."
  @enforce_keys [:tenant_id, :author_user_ids, :deadline_ms]
  defstruct [:tenant_id, :conversation_id, :author_user_ids, :deadline_ms]

  @type t :: %__MODULE__{
          tenant_id: binary(),
          conversation_id: binary() | nil,
          author_user_ids: [binary()],
          deadline_ms: integer()
        }
end
