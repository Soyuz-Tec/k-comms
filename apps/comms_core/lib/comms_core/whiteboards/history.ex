defmodule CommsCore.Whiteboards.History do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Whiteboards.{Operation, Projector, Snapshot, Snapshots, Whiteboard}

  def list(conversation_id, subject, opts) when is_binary(conversation_id) and is_list(opts) do
    after_sequence = integer(Keyword.get(opts, :after_sequence, 0), 0) |> max(0)
    limit = integer(Keyword.get(opts, :limit, 500), 500) |> max(1) |> min(500)
    # Opt-in. An older client that does not ask keeps receiving the full replay,
    # so a rolled-back application image still serves a complete scene.
    snapshot? = Keyword.get(opts, :snapshot, false) == true

    with :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      tenant_id = value(subject, :tenant_id)

      case Repo.get_by(Whiteboard, tenant_id: tenant_id, conversation_id: conversation_id) do
        nil ->
          {:ok,
           %{operations: [], snapshot: nil, has_more: false, next_after_sequence: after_sequence}}

        %Whiteboard{} = whiteboard ->
          snapshot = snapshot_for(whiteboard, after_sequence, snapshot?)
          replay_after = replay_after(whiteboard, snapshot, after_sequence)

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
             snapshot: snapshot_view(snapshot),
             has_more: length(operations) > limit,
             next_after_sequence: next_sequence(page, snapshot, after_sequence)
           }}
      end
    end
  end

  # A snapshot only ever replaces a *fresh* replay. An incremental caller is
  # already holding a scene, and handing it a snapshot would discard edits it
  # applied locally but has not yet read back.
  defp snapshot_for(%Whiteboard{} = whiteboard, 0, true), do: Snapshots.current(whiteboard.id)
  defp snapshot_for(_whiteboard, _after_sequence, _snapshot?), do: nil

  defp snapshot_view(nil), do: nil

  defp snapshot_view(%Snapshot{} = snapshot) do
    %{elements: Snapshots.elements(snapshot), through_sequence: snapshot.through_sequence}
  end

  # With a snapshot the tail starts where the snapshot ended; without one the
  # fresh-replay boundary is the latest clear, as before.
  defp replay_after(_whiteboard, %Snapshot{through_sequence: through}, 0), do: through

  defp replay_after(%Whiteboard{id: whiteboard_id}, nil, 0) do
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

  defp replay_after(_whiteboard, _snapshot, after_sequence), do: after_sequence

  # An empty page after a snapshot still advances the caller: the snapshot
  # itself carries the scene up to its own sequence.
  defp next_sequence([], %Snapshot{through_sequence: through}, _fallback), do: through
  defp next_sequence([], _snapshot, fallback), do: fallback
  defp next_sequence(operations, _snapshot, _fallback), do: List.last(operations).sequence

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
