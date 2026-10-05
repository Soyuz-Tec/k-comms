defmodule CommsCore.SharedDocuments.OperationPage do
  @moduledoc "Bounded replay pinned to the current document generation."
  defstruct [:generation, :through_version, :next_after_version, operations: [], has_more: false]

  @type t :: %__MODULE__{
          generation: pos_integer(),
          through_version: non_neg_integer(),
          next_after_version: non_neg_integer(),
          operations: [CommsCore.SharedDocuments.OperationView.t()],
          has_more: boolean()
        }
end
