defmodule CommsCore.AudioCalls.CalendarSync.SourceContributionReceipt do
  @moduledoc "Same-transaction source receipt. It conveys no provider or workspace authority."
  @enforce_keys [
    :tenant_id,
    :meeting_id,
    :actor_user_id,
    :connection_ids,
    :eligible_export_user_ids,
    :transaction_id,
    :deadline_ms
  ]
  defstruct [
    :tenant_id,
    :meeting_id,
    :actor_user_id,
    :connection_ids,
    :eligible_export_user_ids,
    :transaction_id,
    :deadline_ms
  ]

  @type t :: %__MODULE__{
          tenant_id: binary(),
          meeting_id: binary(),
          actor_user_id: binary(),
          connection_ids: [binary()],
          eligible_export_user_ids: [binary()],
          transaction_id: integer(),
          deadline_ms: integer()
        }
end
