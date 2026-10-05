defmodule CommsCore.Governance.HistoryEvent do
  @moduledoc "Allowlisted lifecycle facts; arbitrary Audit metadata is never included."
  @enforce_keys [:id, :actor, :inserted_at, :action, :proof_versions, :counts]
  defstruct [
    :id,
    :actor,
    :inserted_at,
    :action,
    :status,
    :attempt,
    :error_code,
    :version,
    :proof_versions,
    :counts
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          actor: CommsCore.Governance.HistoryActor.t(),
          inserted_at: DateTime.t(),
          action: String.t(),
          status: :pending | :approved | :rejected | :cancelled | :in_progress | :completed | nil,
          attempt: non_neg_integer() | nil,
          error_code: :provider_failure | :verification_pending | :unavailable | nil,
          version: pos_integer() | nil,
          proof_versions: %{optional(String.t()) => non_neg_integer()},
          counts: %{optional(String.t()) => non_neg_integer()}
        }
end
