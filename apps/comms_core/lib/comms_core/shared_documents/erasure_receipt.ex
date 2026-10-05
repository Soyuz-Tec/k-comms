defmodule CommsCore.SharedDocuments.ErasureReceipt do
  @moduledoc "Content-free synchronous governed erasure receipt."
  defstruct documents_erased: 0, operations_deleted: 0

  @type t :: %__MODULE__{
          documents_erased: non_neg_integer(),
          operations_deleted: non_neg_integer()
        }
end
