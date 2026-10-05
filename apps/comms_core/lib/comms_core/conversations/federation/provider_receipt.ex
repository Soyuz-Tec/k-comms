defmodule CommsCore.Conversations.Federation.ProviderReceipt do
  @moduledoc "Exact private Matrix observation. Local observations never attest cross-server deletion."
  @derive {Inspect, only: [:operation, :remote_deletion_confirmed]}
  @enforce_keys [:operation]
  defstruct [
    :operation,
    :room_id,
    :event_id,
    :state,
    :local_redaction_observed,
    :local_absence_observed,
    :local_leave_observed,
    :cursor,
    :events,
    :joined,
    remote_deletion_confirmed: false
  ]

  @type t :: %__MODULE__{}
end
