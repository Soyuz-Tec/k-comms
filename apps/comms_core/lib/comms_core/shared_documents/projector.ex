defmodule CommsCore.SharedDocuments.Projector do
  @moduledoc false
  alias CommsCore.SharedDocuments.{DocumentView, OperationView, Rga}

  # Every operation retains 512 metadata bytes plus nonempty JSON.
  # With at most 512 bytes left, no admitted operation can fit.
  def document(document),
    do: %DocumentView{
      id: document.id,
      conversation_id: document.conversation_id,
      title: document.title,
      content: document.content,
      generation: document.generation,
      version: document.version,
      updated_at: document.updated_at,
      atoms: Enum.map(document.atoms, &atom/1),
      readonly:
        document.retained_operation_bytes >= 16_776_704 or document.version >= 4_000 or
          length(document.atoms) >= Rga.maximum_atoms() or length(document.author_user_ids) >= 250
    }

  def summary(document, retained_atom_count),
    do: %CommsCore.SharedDocuments.SummaryView{
      id: document.id,
      conversation_id: document.conversation_id,
      title: document.title,
      excerpt: String.slice(document.content, 0, 240),
      generation: document.generation,
      version: document.version,
      updated_at: document.updated_at,
      readonly:
        document.retained_operation_bytes >= 16_776_704 or document.version >= 4_000 or
          retained_atom_count >= Rga.maximum_atoms() or length(document.author_user_ids) >= 250
    }

  def operation(operation),
    do: %OperationView{
      document_id: operation.document_id,
      conversation_id: operation.conversation_id,
      client_operation_id: operation.client_operation_id,
      generation: operation.generation,
      version: operation.version,
      kind: operation.kind,
      title: operation.payload["title"],
      inserted_at: operation.inserted_at,
      inserted_atoms: Enum.map(operation.payload["inserted_atoms"] || [], &atom/1),
      deleted_atom_ids: operation.payload["deleted_atom_ids"] || []
    }

  defp atom(atom),
    do: %{
      id: atom["id"],
      after_id: atom["after_id"],
      text: atom["text"],
      deleted: atom["deleted"],
      order: atom["order"]
    }
end
