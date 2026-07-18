defmodule CommsCore.Attachments.ScanAttemptView do
  @moduledoc "Persistence-neutral attachment scan-attempt projection."

  @enforce_keys [:id, :attachment_id, :attempt_number, :provider, :status]
  defstruct [
    :id,
    :attachment_id,
    :attempt_number,
    :provider,
    :status,
    :verdict,
    :error_code,
    :provider_reference,
    :started_at,
    :completed_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          attachment_id: Ecto.UUID.t(),
          attempt_number: pos_integer(),
          provider: String.t(),
          status: atom(),
          verdict: String.t() | nil,
          error_code: String.t() | nil,
          provider_reference: String.t() | nil,
          started_at: DateTime.t(),
          completed_at: DateTime.t()
        }
end
