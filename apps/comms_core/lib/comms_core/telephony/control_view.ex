defmodule CommsCore.Telephony.ControlView do
  @moduledoc "Durable telephone control receipt. Submitted does not assert carrier delivery."
  @enforce_keys [:id, :call_id, :action, :status, :dispatch, :created_at, :expires_at]
  defstruct [
    :id,
    :call_id,
    :action,
    :status,
    :dispatch,
    :created_at,
    :expires_at,
    :completed_at,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          call_id: String.t(),
          action: atom(),
          status: atom(),
          dispatch: boolean(),
          created_at: DateTime.t(),
          expires_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          failure_reason: String.t() | nil
        }
end
