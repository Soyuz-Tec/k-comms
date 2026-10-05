defmodule CommsCore.SharedDocuments.Queries do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Repo

  alias CommsCore.SharedDocuments.{
    Authority,
    Commands,
    Document,
    Operation,
    OperationPage,
    Projector
  }

  def get(id, subject),
    do: Commands.with_document(id, subject, fn document, _ -> Projector.document(document) end)

  def authorize(id, subject),
    do:
      Commands.with_document(id, subject, fn _document, _ -> :ok end, [
        :id,
        :tenant_id,
        :conversation_id,
        :author_user_ids,
        :lineage_verified,
        :erased_at
      ])

  def list(conversation_id, query, subject) when is_binary(query) and byte_size(query) <= 640 do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         true <- String.valid?(query) and length(String.codepoints(query)) <= 160 do
      deadline = Authority.deadline()

      Repo.transaction(
        fn ->
          Authority.lock!(conversation_id, subject, deadline)

          documents =
            Repo.all(
              from(document in Document,
                where:
                  document.tenant_id == ^Authority.value(subject, :tenant_id) and
                    document.conversation_id == ^conversation_id and is_nil(document.erased_at),
                order_by: [desc: document.updated_at, asc: document.id],
                limit: 40,
                lock: "FOR SHARE",
                select:
                  {struct(document, [
                     :id,
                     :tenant_id,
                     :conversation_id,
                     :title,
                     :content,
                     :generation,
                     :version,
                     :updated_at,
                     :retained_operation_bytes,
                     :author_user_ids,
                     :lineage_verified,
                     :erased_at
                   ]), fragment("cardinality(?)", document.atoms)}
              )
            )

          documents =
            Enum.filter(documents, fn {document, _count} ->
              Authority.document!(document)

              query == "" or
                String.contains?(
                  String.downcase(document.title <> "\n" <> document.content),
                  String.downcase(query)
                )
            end)

          result =
            Enum.map(documents, fn {document, count} -> Projector.summary(document, count) end)

          Authority.current!(conversation_id, subject, deadline)
          result
        end,
        timeout: 20_000
      )
    else
      _ -> {:error, :invalid_search_query}
    end
  end

  def list(_, _, _), do: {:error, :invalid_search_query}

  def replay(id, generation, after_version, limit, subject)
      when is_integer(generation) and generation >= 1 and is_integer(after_version) and
             after_version >= 0 and is_integer(limit) and limit in 1..100 do
    Commands.with_document(id, subject, fn document, _ ->
      if generation != document.generation, do: Repo.rollback(:stale_document_generation)
      if after_version > document.version, do: Repo.rollback(:invalid_document_operation)

      operations =
        Repo.all(
          from(op in Operation,
            where: op.document_id == ^document.id and op.version > ^after_version,
            order_by: [asc: op.version],
            limit: ^(limit + 1)
          )
        )

      page = Enum.take(operations, limit)

      %OperationPage{
        generation: generation,
        through_version: document.version,
        operations: Enum.map(page, &Projector.operation/1),
        has_more: length(operations) > limit,
        next_after_version: if(page == [], do: after_version, else: List.last(page).version)
      }
    end)
  end

  def replay(_, _, _, _, _), do: {:error, :invalid_document_operation}

  def export(id, subject),
    do: Commands.with_document(id, subject, fn document, _ -> Projector.document(document) end)
end
