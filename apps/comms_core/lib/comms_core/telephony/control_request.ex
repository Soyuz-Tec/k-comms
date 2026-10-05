defmodule CommsCore.Telephony.ControlRequest do
  @moduledoc "Exact server-owned SIP participant and allowlisted transfer request."
  @enforce_keys [
    :command_id,
    :call_id,
    :tenant_id,
    :action,
    :provider_room,
    :provider_identity,
    :destination,
    :pbx_state
  ]
  defstruct [
    :command_id,
    :call_id,
    :tenant_id,
    :action,
    :provider_room,
    :provider_identity,
    :destination,
    :pbx_state,
    :notice_media,
    :notice_completed_at,
    :expires_at,
    :call_expires_at,
    system: false,
    reconcile: false
  ]

  @type t :: %__MODULE__{
          command_id: String.t(),
          call_id: String.t(),
          action: atom(),
          tenant_id: String.t(),
          pbx_state: map(),
          reconcile: boolean(),
          provider_room: String.t(),
          provider_identity: String.t(),
          destination: String.t()
        }
end
