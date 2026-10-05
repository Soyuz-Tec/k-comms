defmodule CommsCore.AudioCalls.ArtifactSummaryReceipt do
  @moduledoc "Actual bounded local selected-quote result bound to its submitted transcript digest."
  @enforce_keys [:provider_id, :model, :source_sha256, :text]
  defstruct [:provider_id, :model, :source_sha256, :text]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          model: String.t(),
          source_sha256: String.t(),
          text: String.t()
        }
end
