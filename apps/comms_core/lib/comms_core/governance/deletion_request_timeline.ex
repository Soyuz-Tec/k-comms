defmodule CommsCore.Governance.DeletionRequestTimeline do
  @moduledoc "Bounded chronological request history and its retained-source coverage."
  @enforce_keys [
    :request,
    :events,
    :limit,
    :snapshot,
    :observed_at,
    :snapshot_observed_at,
    :coverage
  ]
  defstruct [
    :request,
    :events,
    :limit,
    :next_cursor,
    :snapshot,
    :observed_at,
    :snapshot_observed_at,
    :coverage
  ]

  @type coverage :: %{
          state: :available | :partial | :unavailable,
          retained_only: true,
          version_lineage: :unproven,
          origin_present: boolean(),
          earliest_at: DateTime.t() | nil,
          snapshot_truncated: boolean(),
          captured_count: 0..5_000,
          retained_count: 0..5_000,
          maximum_events: 5_000
        }
  @type t :: %__MODULE__{
          request: CommsCore.Governance.DeletionRequestView.t(),
          events: [CommsCore.Governance.HistoryEvent.t()],
          limit: 1..50,
          next_cursor: String.t() | nil,
          snapshot: String.t(),
          observed_at: DateTime.t(),
          snapshot_observed_at: DateTime.t(),
          coverage: coverage()
        }
end
