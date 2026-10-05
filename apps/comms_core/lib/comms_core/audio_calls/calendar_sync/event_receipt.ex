defmodule CommsCore.AudioCalls.CalendarSync.EventReceipt do
  @moduledoc "A stripped provider result, never raw event text or a provider error body."
  @derive {Inspect, except: [:external_id, :etag]}
  @enforce_keys [:provider, :outcome]
  defstruct [:provider, :outcome, :external_id, :etag, :retry_after_seconds, verified_ids: []]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          outcome:
            :applied
            | :present
            | :absent
            | :removal_accepted
            | :conflict
            | :duplicate
            | :denied
            | :reauthorization_required
            | :retryable
            | :uncertain,
          external_id: binary() | nil,
          etag: binary() | nil,
          retry_after_seconds: non_neg_integer() | nil,
          verified_ids: [binary()]
        }
end
