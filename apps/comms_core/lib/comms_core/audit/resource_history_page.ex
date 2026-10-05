defmodule CommsCore.Audit.ResourceHistoryPage do
  @moduledoc "Retained members of an immutable, bounded audit-ID snapshot."
  @enforce_keys [
    :events,
    :has_more,
    :through,
    :origin_present,
    :earliest_at,
    :snapshot_id,
    :observed_at,
    :expires_at,
    :captured_count,
    :retained_count,
    :snapshot_truncated
  ]
  defstruct [
    :events,
    :has_more,
    :through,
    :origin_present,
    :earliest_at,
    :snapshot_id,
    :observed_at,
    :expires_at,
    :captured_count,
    :retained_count,
    :snapshot_truncated
  ]

  @type t :: %__MODULE__{
          events: [CommsCore.Audit.Event.t()],
          has_more: boolean(),
          through: CommsCore.Audit.ResourceHistoryQuery.boundary() | nil,
          origin_present: boolean(),
          earliest_at: DateTime.t() | nil,
          snapshot_id: Ecto.UUID.t(),
          observed_at: DateTime.t(),
          expires_at: DateTime.t(),
          captured_count: 0..5_000,
          retained_count: 0..5_000,
          snapshot_truncated: boolean()
        }
end
