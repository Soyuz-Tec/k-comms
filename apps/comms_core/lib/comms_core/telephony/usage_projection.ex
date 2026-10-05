defmodule CommsCore.Telephony.UsageProjection do
  @moduledoc "Content-free observed aggregates over currently retained owner records."
  @enforce_keys [:observed_at, :earliest_retained_at, :current, :daily]
  defstruct [:observed_at, :earliest_retained_at, :current, :daily]

  @type metric ::
          :current_ringing
          | :current_answered
          | :started
          | :inbound_started
          | :outbound_started
          | :status_ringing
          | :status_answered
          | :status_declined
          | :status_no_answer
          | :status_cancelled
          | :status_failed
          | :status_ended
          | :status_busy
          | :observed_answered_seconds
  @type counts :: %{optional(metric()) => non_neg_integer()}
  @type day :: %{required(:date) => Date.t(), required(:metrics) => counts()}
  @type t :: %__MODULE__{
          observed_at: DateTime.t(),
          earliest_retained_at: DateTime.t() | nil,
          current: counts(),
          daily: [day()]
        }
end
