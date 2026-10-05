defmodule CommsCore.SharedDocuments.ReleaseInventory do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.SharedDocuments.{Document, Operation}
  def hazard_count(repo), do: repo.aggregate(Document, :count) + repo.aggregate(Operation, :count)

  def fingerprint(repo, tenant_id),
    do: %{
      shared_documents:
        repo.all(
          from(document in Document, where: document.tenant_id == ^tenant_id, select: document.id)
        ),
      shared_document_operations:
        repo.all(from(op in Operation, where: op.tenant_id == ^tenant_id, select: op.id))
    }
end
