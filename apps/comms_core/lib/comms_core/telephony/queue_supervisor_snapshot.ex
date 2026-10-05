defmodule CommsCore.Telephony.QueueSupervisorSnapshot do
  @moduledoc "Authorized current retained-call aggregates; no callers, members or history."
  @type route :: %{
          id: String.t(),
          name: String.t(),
          mode: :queue | :shared_line,
          enabled: boolean(),
          configured_members: non_neg_integer(),
          max_waiting: pos_integer(),
          max_wait_seconds: pos_integer(),
          waiting_calls: non_neg_integer(),
          offered_calls: non_neg_integer(),
          answered_calls: non_neg_integer(),
          oldest_observed_wait_seconds: non_neg_integer() | nil
        }
  @type t :: %{
          routes: [route()],
          observed_at: DateTime.t(),
          coverage: String.t(),
          online_presence_observed: false,
          historical_service_level_available: false,
          oldest_wait_basis: String.t()
        }
end
