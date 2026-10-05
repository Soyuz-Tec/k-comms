defmodule CommsCore.SharedDocuments.Commands do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Repo
  alias CommsCore.SharedDocuments.{Authority, Document, Operation, Projector, Rga}

  def create(conversation_id, attrs, subject) when is_binary(conversation_id) and is_map(attrs) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         {:ok, client_id} <- Ecto.UUID.cast(Authority.value(attrs, :client_document_id)),
         {:ok, title} <- title(Authority.value(attrs, :title)) do
      deadline = Authority.deadline()

      Repo.transaction(
        fn ->
          Authority.lock!(conversation_id, subject, deadline)
          create_locked!(conversation_id, client_id, title, subject, nil, deadline)
        end,
        timeout: 20_000
      )
    else
      _ -> {:error, :invalid_document_operation}
    end
  end

  def create(_, _, _), do: {:error, :invalid_document_operation}

  def copy(document_id, attrs, subject) when is_map(attrs) do
    with {:ok, client_id} <- Ecto.UUID.cast(Authority.value(attrs, :client_document_id)),
         {:ok, title} <- title(Authority.value(attrs, :title)) do
      with_document(document_id, subject, fn source, deadline ->
        create_locked!(source.conversation_id, client_id, title, subject, source, deadline)
      end)
    else
      _ -> {:error, :invalid_document_operation}
    end
  end

  def copy(_, _, _), do: {:error, :invalid_document_operation}

  def apply_operation(document_id, attrs, subject) when is_map(attrs) do
    with {:ok, client_id} <- Ecto.UUID.cast(Authority.value(attrs, :client_operation_id)),
         generation when is_integer(generation) and generation >= 1 <-
           Authority.value(attrs, :generation),
         base_version when is_integer(base_version) and base_version >= 0 <-
           Authority.value(attrs, :base_version),
         kind when kind in ["edit", "rename"] <- Authority.value(attrs, :kind),
         {:ok, input} <- normalize_input(kind, attrs, generation, base_version) do
      with_document(document_id, subject, fn document, deadline ->
        if generation != document.generation, do: Repo.rollback(:stale_document_generation)

        existing =
          Repo.get_by(Operation, document_id: document.id, client_operation_id: client_id)

        result =
          case existing do
            %Operation{} = operation ->
              if operation.actor_user_id == Authority.value(subject, :user_id) and
                   operation.actor_device_id == Authority.value(subject, :device_id) and
                   operation.input == input do
                {Projector.operation(operation), :duplicate}
              else
                Repo.rollback(:idempotency_conflict)
              end

            nil ->
              if document.version >= 4_000, do: Repo.rollback(:document_capacity_exceeded)
              if base_version > document.version, do: Repo.rollback(:invalid_document_operation)

              if kind == "rename" and base_version != document.version,
                do: Repo.rollback(:stale_version)

              authors =
                Enum.uniq(document.author_user_ids ++ [Authority.value(subject, :user_id)])

              if length(authors) > 250, do: Repo.rollback(:document_capacity_exceeded)
              version = document.version + 1

              {updated_attrs, payload} =
                case kind do
                  "rename" ->
                    {%{title: input["title"]},
                     %{
                       "title" => input["title"],
                       "inserted_atoms" => [],
                       "deleted_atom_ids" => []
                     }}

                  "edit" ->
                    case Rga.apply(document.atoms, input["changes"], client_id, version) do
                      {:ok, atoms, content, inserted, deleted} ->
                        {%{atoms: atoms, content: content},
                         %{"inserted_atoms" => inserted, "deleted_atom_ids" => deleted}}

                      {:error, reason} ->
                        Repo.rollback(reason)
                    end
                end

              Authority.current!(document.conversation_id, subject, deadline)

              operation =
                insert_operation!(document, subject, client_id, kind, input, payload, version)

              document
              |> Ecto.Changeset.change(
                Map.merge(updated_attrs, %{version: version, author_user_ids: authors})
              )
              |> Repo.update!()

              {Projector.operation(operation), :created}
          end

        Authority.current!(document.conversation_id, subject, deadline)
        result
      end)
      |> case do
        {:ok, {operation, status}} -> {:ok, operation, status}
        error -> error
      end
    else
      _ -> {:error, :invalid_document_operation}
    end
  end

  def apply_operation(_, _, _), do: {:error, :invalid_document_operation}

  def with_document(document_id, subject, operation, projection_fields \\ nil) do
    with {:ok, document_id} <- Ecto.UUID.cast(document_id),
         %Document{} = observed <-
           Repo.one(
             from(document in Document,
               where:
                 document.id == ^document_id and
                   document.tenant_id == ^Authority.value(subject, :tenant_id),
               select: struct(document, [:id, :tenant_id, :conversation_id])
             )
           ) do
      deadline = Authority.deadline()

      Repo.transaction(
        fn ->
          Authority.lock!(observed.conversation_id, subject, deadline)

          query =
            from(document in Document,
              where: document.id == ^document_id and document.tenant_id == ^observed.tenant_id,
              lock: "FOR UPDATE"
            )

          query =
            if projection_fields,
              do: from(document in query, select: struct(document, ^projection_fields)),
              else: query

          document = Repo.one(query)
          if is_nil(document), do: Repo.rollback(:not_found)
          Authority.document!(document)
          Authority.budget!(deadline)
          result = operation.(document, deadline)
          Authority.current!(document.conversation_id, subject, deadline)
          result
        end,
        timeout: 20_000
      )
    else
      _ -> {:error, :not_found}
    end
  end

  defp create_locked!(conversation_id, client_id, title, subject, source, deadline) do
    tenant_id = Authority.value(subject, :tenant_id)
    actor_id = Authority.value(subject, :user_id)
    device_id = Authority.value(subject, :device_id)
    Authority.current!(conversation_id, subject, deadline)

    case Repo.get_by(Document,
           tenant_id: tenant_id,
           conversation_id: conversation_id,
           client_document_id: client_id
         ) do
      %Document{} = existing ->
        Authority.document!(existing)

        operation =
          Repo.one!(
            from(op in Operation, where: op.document_id == ^existing.id and op.version == 1)
          )

        expected = %{
          "title" => title,
          "source_document_id" => if(source, do: source.id, else: nil)
        }

        if existing.created_by_user_id == actor_id and existing.created_by_device_id == device_id and
             operation.input == expected do
          Projector.document(existing)
        else
          Repo.rollback(:idempotency_conflict)
        end

      nil ->
        count =
          Repo.aggregate(
            from(document in Document,
              where:
                document.tenant_id == ^tenant_id and document.conversation_id == ^conversation_id
            ),
            :count
          )

        tenant_count =
          Repo.aggregate(
            from(document in Document, where: document.tenant_id == ^tenant_id),
            :count
          )

        if count >= 40 or tenant_count >= 1_000, do: Repo.rollback(:document_capacity_exceeded)
        authors = Enum.uniq([actor_id | if(source, do: source.author_user_ids, else: [])])
        if length(authors) > 250, do: Repo.rollback(:document_capacity_exceeded)
        # Copies retain source lineage, but rebase their atom IDs to a distinct
        # document operation; source tombstones and immutable history stay owned.
        {atoms, content, inserted} =
          if source do
            copy_atoms(source.content, client_id)
          else
            {[], "", []}
          end

        document =
          %Document{}
          |> Document.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation_id,
            created_by_user_id: actor_id,
            created_by_device_id: device_id,
            client_document_id: client_id,
            title: title,
            content: content,
            atoms: atoms,
            author_user_ids: authors,
            generation: 1,
            version: 1
          })
          |> Repo.insert!()

        insert_operation!(
          document,
          subject,
          client_id,
          if(source, do: "copy", else: "create"),
          %{"title" => title, "source_document_id" => if(source, do: source.id, else: nil)},
          %{"title" => title, "inserted_atoms" => inserted, "deleted_atom_ids" => []},
          1
        )

        Authority.current!(conversation_id, subject, deadline)
        Authority.budget!(deadline)
        Projector.document(Repo.get!(Document, document.id))
    end
  end

  defp copy_atoms(content, operation_id) do
    {atoms, _} =
      Enum.reduce(Enum.with_index(String.codepoints(content)), {[], nil}, fn {text, index},
                                                                             {atoms, anchor} ->
        atom = %{
          "id" => operation_id <> ":" <> Integer.to_string(index),
          "after_id" => anchor,
          "text" => text,
          "deleted" => false,
          "order" => 32_000 + index
        }

        {[atom | atoms], atom["id"]}
      end)

    ordered = Enum.reverse(atoms)
    {ordered, content, ordered}
  end

  defp insert_operation!(document, subject, client_id, kind, input, payload, version) do
    retained_bytes =
      document.retained_operation_bytes + byte_size(Jason.encode!(input)) +
        byte_size(Jason.encode!(payload)) + 512

    if retained_bytes > 16_777_216, do: Repo.rollback(:document_capacity_exceeded)

    operation =
      %Operation{}
      |> Operation.changeset(%{
        tenant_id: document.tenant_id,
        conversation_id: document.conversation_id,
        document_id: document.id,
        actor_user_id: Authority.value(subject, :user_id),
        actor_device_id: Authority.value(subject, :device_id),
        client_operation_id: client_id,
        generation: document.generation,
        version: version,
        kind: kind,
        input: input,
        payload: payload
      })
      |> Repo.insert!()

    document |> Ecto.Changeset.change(retained_operation_bytes: retained_bytes) |> Repo.update!()
    operation
  end

  defp normalize_input("edit", attrs, generation, base_version) do
    changes = Authority.value(attrs, :changes)

    if is_list(changes),
      do:
        {:ok, %{"generation" => generation, "base_version" => base_version, "changes" => changes}},
      else: {:error, :invalid_document_operation}
  end

  defp normalize_input("rename", attrs, generation, base_version) do
    with {:ok, title} <- title(Authority.value(attrs, :title)),
         do:
           {:ok, %{"generation" => generation, "base_version" => base_version, "title" => title}}
  end

  defp title(value) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) and length(String.codepoints(value)) in 1..160 and
         byte_size(value) <= 640 and
         not String.contains?(value, "\0"),
       do: {:ok, value},
       else: {:error, :invalid_document_operation}
  end

  defp title(_), do: {:error, :invalid_document_operation}
end
