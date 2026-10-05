defmodule CommsCore.Governance.DeletionRequestHistoryExport do
  @moduledoc "Formula-neutralized CSV of an authorized retained-history bound."
  @enforce_keys [
    :csv,
    :filename,
    :count,
    :truncated,
    :maximum_rows,
    :snapshot,
    :observed_at,
    :coverage
  ]
  defstruct [
    :csv,
    :filename,
    :count,
    :truncated,
    :maximum_rows,
    :snapshot,
    :observed_at,
    :coverage
  ]

  @type t :: %__MODULE__{
          csv: binary(),
          filename: String.t(),
          count: non_neg_integer(),
          truncated: boolean(),
          maximum_rows: 5_000,
          snapshot: String.t(),
          observed_at: DateTime.t(),
          coverage: CommsCore.Governance.DeletionRequestTimeline.coverage()
        }
end
