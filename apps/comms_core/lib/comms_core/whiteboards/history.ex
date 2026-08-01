defmodule CommsCore.Whiteboards.History do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Whiteboards.{Operation, Projector, Whiteboard}

  def list(conversation_id, subject, opts) when is_binary(conversation_id) and is_list(opts) do
    after_sequence = integer(Keyword.get(opts, :after_sequence, 0), 0) |> max(0)
    limit = integer(Keyword.get(opts, :limit, 500), 500) |> max(1) |> min(500)

    with :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      tenant_id = value(subject, :tenant_id)

      case Repo.get_by(Whiteboard, tenant_id: tenant_id, conversation_id: conversation_id) do
        nil ->
          {:ok, %{operations: [], has_more: false, next_after_sequence: after_sequence}}

        %Whiteboard{} = whiteboard ->
          replay_after = replay_after(whiteboard.id, after_sequence)

          operations =
            Repo.all(
              from(operation in Operation,
                where:
                  operation.whiteboard_id == ^whiteboard.id and
                    operation.sequence > ^replay_after,
                order_by: [asc: operation.sequence],
                limit: ^(limit + 1)
              )
            )

          page = Enum.take(operations, limit)

          {:ok,
           %{
             operations: Enum.map(page, &Projector.operation/1),
             has_more: length(operations) > limit,
             next_after_sequence: next_sequence(page, after_sequence)
           }}
      end
    end
  end

  defp replay_after(whiteboard_id, 0) do
    case Repo.one(
           from(operation in Operation,
             where: operation.whiteboard_id == ^whiteboard_id and operation.kind == "board.clear",
             select: max(operation.sequence)
           )
         ) do
      nil -> 0
      clear_sequence -> clear_sequence - 1
    end
  end

  defp replay_after(_whiteboard_id, after_sequence), do: after_sequence

  defp next_sequence([], fallback), do: fallback
  defp next_sequence(operations, _fallback), do: List.last(operations).sequence

  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
