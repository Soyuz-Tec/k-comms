defmodule CommsCore.SharedDocuments.Erasure do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Repo
  alias CommsCore.SharedDocuments.{Authority, Document, ErasureReceipt, Operation}

  def erase(tenant_id, target_type, target_id, %DateTime{} = timestamp)
      when target_type in [:user, :conversation] do
    if Repo.in_transaction?() do
      with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
           {:ok, target_id} <- Ecto.UUID.cast(target_id) do
        deadline = Authority.deadline()
        Authority.budget!(deadline)
        # The owner contribution is safe on any caller transaction: retain
        # Governance before selecting or locking document resources.
        Authority.protect!(
          tenant_id,
          if(target_type == :conversation, do: target_id, else: nil),
          if(target_type == :user, do: [target_id], else: []),
          :erase
        )

        Authority.budget!(deadline)

        query =
          from(document in Document,
            where: document.tenant_id == ^tenant_id and is_nil(document.erased_at)
          )

        query =
          case target_type do
            :user ->
              from(document in query,
                where:
                  ^target_id in document.author_user_ids or not document.lineage_verified or
                    fragment("cardinality(?) = 0", document.author_user_ids)
              )

            :conversation ->
              from(document in query, where: document.conversation_id == ^target_id)
          end

        documents =
          Repo.all(
            from(document in query,
              order_by: [asc: document.id],
              limit: 1_001,
              lock: "FOR UPDATE",
              select:
                struct(document, [
                  :id,
                  :tenant_id,
                  :conversation_id,
                  :author_user_ids,
                  :lineage_verified,
                  :erased_at
                ])
            )
          )

        if length(documents) > 1_000, do: Repo.rollback(:document_erasure_scope_exceeded)

        Enum.each(documents, fn document ->
          Authority.budget!(deadline)
          Authority.document!(document, :erase)
        end)

        Authority.budget!(deadline)
        ids = Enum.map(documents, & &1.id)

        {operations, _} =
          Repo.delete_all(
            from(op in Operation, where: op.tenant_id == ^tenant_id and op.document_id in ^ids)
          )

        {count, _} =
          Repo.update_all(
            from(document in Document,
              where: document.tenant_id == ^tenant_id and document.id in ^ids
            ),
            set: [
              title: "Erased document",
              content: "",
              atoms: [],
              author_user_ids: [],
              created_by_user_id: nil,
              created_by_device_id: nil,
              retained_operation_bytes: 0,
              erased_at: timestamp,
              updated_at: timestamp
            ],
            inc: [generation: 1, version: 1]
          )

        Authority.budget!(deadline)
        {:ok, %ErasureReceipt{documents_erased: count, operations_deleted: operations}}
      else
        _ -> {:error, :invalid_erasure_scope}
      end
    else
      {:error, :transaction_required}
    end
  end

  def erase(_, _, _, _), do: {:error, :invalid_erasure_scope}
end
