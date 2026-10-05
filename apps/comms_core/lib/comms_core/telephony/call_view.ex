defmodule CommsCore.Telephony.CallView do
  @moduledoc "Persistence-free individual telephone call and durable CDR projection."
  @enforce_keys [
    :id,
    :direction,
    :status,
    :from_number,
    :to_number,
    :extension,
    :started_at,
    :connected_seconds,
    :can_answer,
    :can_join,
    :can_end,
    :active_on_this_device
  ]
  defstruct [
    :id,
    :direction,
    :status,
    :from_number,
    :to_number,
    :extension,
    :started_at,
    :answered_at,
    :ended_at,
    :end_reason,
    :control_state,
    :connected_seconds,
    :can_answer,
    :can_join,
    :can_end,
    :active_on_this_device
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          direction: :inbound | :outbound,
          status: atom(),
          from_number: String.t(),
          to_number: String.t(),
          extension: String.t(),
          started_at: DateTime.t(),
          answered_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          end_reason: String.t() | nil,
          connected_seconds: non_neg_integer(),
          can_answer: boolean(),
          can_join: boolean(),
          can_end: boolean(),
          active_on_this_device: boolean()
        }
end
