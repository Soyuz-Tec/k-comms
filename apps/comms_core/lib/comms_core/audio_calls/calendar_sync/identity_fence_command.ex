defmodule CommsCore.AudioCalls.CalendarSync.IdentityFenceCommand do
  @moduledoc "Delete-only contribution under an already-retained exact Identity User parent."
  @enforce_keys [:tenant_id, :user_id, :reason, :deadline_ms]
  defstruct [:tenant_id, :user_id, :reason, :deadline_ms]

  @type t :: %__MODULE__{
          tenant_id: binary(),
          user_id: binary(),
          reason: :user_suspended | :workspace_scope_withdrawn | :governance_erasure,
          deadline_ms: integer()
        }
end
