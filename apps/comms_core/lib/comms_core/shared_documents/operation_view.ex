defmodule CommsCore.SharedDocuments.OperationView do
  @moduledoc "Committed document operation receipt and replay projection."
  defstruct [
    :document_id,
    :conversation_id,
    :client_operation_id,
    :generation,
    :version,
    :kind,
    :title,
    :inserted_at,
    inserted_atoms: [],
    deleted_atom_ids: []
  ]

  @type t :: %__MODULE__{
          document_id: binary(),
          conversation_id: binary(),
          client_operation_id: binary(),
          generation: pos_integer(),
          version: pos_integer(),
          kind: binary(),
          title: binary() | nil,
          inserted_at: DateTime.t(),
          inserted_atoms: [CommsCore.SharedDocuments.DocumentView.atom_view()],
          deleted_atom_ids: [binary()]
        }
end
