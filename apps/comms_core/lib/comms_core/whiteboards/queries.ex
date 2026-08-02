defmodule CommsCore.Whiteboards.Queries do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Whiteboards.{ActivityView, Operation, SearchResult}

  @max_search_limit 50
  @max_activity_limit 100

  def search(query, subject, opts \\ [])

  def search(query, subject, opts) when is_binary(query) and is_map(subject) do
    query = String.trim(query)

    with true <- String.length(query) in 2..160,
         {:ok, authorized_ids} <- Conversations.active_conversation_ids(subject) do
      conversation_ids =
        authorized_conversation_ids(authorized_ids, Keyword.get(opts, :conversation_id))

      limit = bounded_limit(Keyword.get(opts, :limit, 25), @max_search_limit)

      if conversation_ids == [] do
        {:ok, []}
      else
        sql = """
        WITH elements AS (
          SELECT operation.conversation_id,
                 operation.sequence,
                 operation.inserted_at,
                 element
          FROM whiteboard_operations AS operation
          CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(operation.payload->'elements', '[]'::jsonb)
          ) AS element
          WHERE operation.tenant_id = $1::text::uuid
            AND operation.conversation_id = ANY(($2::text[])::uuid[])
            AND operation.kind = 'scene.update'
        ), latest AS (
          SELECT DISTINCT ON (conversation_id, element->>'id')
                 conversation_id,
                 sequence,
                 inserted_at,
                 element
          FROM elements
          WHERE element ? 'id'
          ORDER BY conversation_id, element->>'id', sequence DESC
        )
        SELECT conversation_id::text,
               element->>'id',
               sequence,
               COALESCE(element->>'text', ''),
               inserted_at
        FROM latest
        WHERE COALESCE((element->>'isDeleted')::boolean, false) = false
          AND COALESCE(element->>'text', '') ILIKE $3 ESCAPE '\\'
        ORDER BY inserted_at DESC, sequence DESC
        LIMIT $4
        """

        pattern = "%" <> escape_like(query) <> "%"

        case Repo.query(sql, [value(subject, :tenant_id), conversation_ids, pattern, limit]) do
          {:ok, %{rows: rows}} ->
            {:ok,
             Enum.map(rows, fn [conversation_id, element_id, sequence, text, inserted_at] ->
               %SearchResult{
                 conversation_id: conversation_id,
                 element_id: element_id,
                 sequence: sequence,
                 text: text,
                 inserted_at: inserted_at
               }
             end)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      false -> {:error, :invalid_search_query}
      {:error, _} = error -> error
    end
  end

  def search(_, _, _), do: {:error, :invalid_search_query}

  def activity(conversation_id, subject, opts \\ [])

  def activity(conversation_id, subject, opts)
      when is_binary(conversation_id) and is_map(subject) do
    with :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      limit = bounded_limit(Keyword.get(opts, :limit, 50), @max_activity_limit)

      entries =
        Operation
        |> where(
          [operation],
          operation.tenant_id == ^value(subject, :tenant_id) and
            operation.conversation_id == ^conversation_id
        )
        |> order_by([operation], desc: operation.inserted_at, desc: operation.sequence)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.map(fn operation ->
          %ActivityView{
            id: operation.id,
            conversation_id: operation.conversation_id,
            actor_user_id: operation.actor_user_id,
            kind: operation.kind,
            sequence: operation.sequence,
            occurred_at: operation.inserted_at
          }
        end)

      {:ok, entries}
    end
  end

  def activity(_, _, _), do: {:error, :not_found}

  defp authorized_conversation_ids(authorized_ids, requested_conversation_id) do
    case requested_conversation_id do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        if conversation_id in authorized_ids, do: [conversation_id], else: []

      _ ->
        authorized_ids
    end
  end

  defp bounded_limit(value, maximum) when is_integer(value), do: value |> max(1) |> min(maximum)

  defp bounded_limit(value, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_limit(integer, maximum)
      _ -> min(25, maximum)
    end
  end

  defp bounded_limit(_, maximum), do: min(25, maximum)

  defp escape_like(value),
    do:
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
