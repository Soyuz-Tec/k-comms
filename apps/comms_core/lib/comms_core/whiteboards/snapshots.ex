defmodule CommsCore.Whiteboards.Snapshots do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo
  alias CommsCore.Whiteboards.{Operation, Snapshot, Whiteboard}

  # How many operations may accumulate before the scene is rematerialised.
  # Small enough that a joining client never pages through much tail; large
  # enough that ordinary drawing does not rebuild on every stroke. Configurable
  # because the right value depends on write volume per board, which differs
  # between a member conversation and a public instant room.
  @default_rebuild_interval 250

  @doc """
  Rematerialise the board's scene if enough operations have accrued.

  Called from inside `Commands.append/3`, whose transaction already holds the
  board row `FOR UPDATE`. That lock is what makes this safe: the snapshot is
  written against exactly the sequence the caller just allocated, so it can
  never record a scene that includes an operation another writer has not
  committed.

  Snapshotting is an optimisation, never a source of truth. Any failure here
  must leave the operation log authoritative and untouched.
  """
  @spec maintain(Whiteboard.t(), pos_integer()) :: :ok
  def maintain(%Whiteboard{} = whiteboard, sequence) when is_integer(sequence) do
    existing = load(whiteboard.id)

    if due?(existing, sequence) do
      rebuild(whiteboard, existing, sequence)
    end

    :ok
  end

  @doc """
  The snapshot a joining client may start from, or `nil`.

  Returns `nil` whenever the snapshot cannot be proven current for the board's
  present generation — after a clear, for instance. Callers then fall back to
  replaying the log, which is always correct and merely slower. A stale
  snapshot must never be served: it would resurrect a cleared scene.
  """
  @spec current(Ecto.UUID.t()) :: Snapshot.t() | nil
  def current(whiteboard_id) when is_binary(whiteboard_id) do
    case load(whiteboard_id) do
      nil ->
        nil

      %Snapshot{} = snapshot ->
        generation = latest_clear_sequence(whiteboard_id)

        if snapshot.generation_sequence == generation and snapshot.through_sequence >= generation do
          snapshot
        end
    end
  end

  @doc "Elements held by a snapshot, in paint order."
  @spec elements(Snapshot.t()) :: [map()]
  def elements(%Snapshot{elements: %{"elements" => elements}}) when is_list(elements),
    do: elements

  def elements(%Snapshot{}), do: []

  defp load(whiteboard_id), do: Repo.get_by(Snapshot, whiteboard_id: whiteboard_id)

  defp due?(nil, sequence), do: sequence >= rebuild_interval()

  defp due?(%Snapshot{through_sequence: through}, sequence),
    do: sequence - through >= rebuild_interval()

  defp rebuild_interval do
    :comms_core
    |> Application.get_env(:whiteboard_snapshot_interval, @default_rebuild_interval)
    |> max(1)
  end

  defp rebuild(%Whiteboard{} = whiteboard, existing, sequence) do
    generation = latest_clear_sequence(whiteboard.id)

    # Resume from the existing snapshot only when it belongs to the current
    # generation. A clear since then invalidates it, and folding new operations
    # onto a pre-clear scene would restore work a collaborator deleted.
    {base_elements, from_sequence} =
      case existing do
        %Snapshot{generation_sequence: ^generation, through_sequence: through}
        when through >= generation ->
          {elements(existing), through}

        _ ->
          {[], generation}
      end

    scene =
      whiteboard.id
      |> operations_between(from_sequence, sequence)
      |> Enum.reduce(base_elements, &apply_operation/2)

    attrs = %{
      whiteboard_id: whiteboard.id,
      tenant_id: whiteboard.tenant_id,
      conversation_id: whiteboard.conversation_id,
      through_sequence: sequence,
      generation_sequence: generation,
      elements: %{"elements" => scene}
    }

    (existing || %Snapshot{})
    |> Snapshot.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp operations_between(whiteboard_id, after_sequence, through_sequence) do
    Repo.all(
      from(operation in Operation,
        where:
          operation.whiteboard_id == ^whiteboard_id and
            operation.sequence > ^after_sequence and
            operation.sequence <= ^through_sequence,
        order_by: [asc: operation.sequence]
      )
    )
  end

  defp latest_clear_sequence(whiteboard_id) do
    Repo.one(
      from(operation in Operation,
        where: operation.whiteboard_id == ^whiteboard_id and operation.kind == "board.clear",
        select: max(operation.sequence)
      )
    ) || 0
  end

  defp apply_operation(%Operation{kind: "board.clear"}, _scene), do: []

  defp apply_operation(%Operation{kind: "scene.update", payload: payload}, scene) do
    merge(scene, Map.get(payload, "elements", []))
  end

  defp apply_operation(%Operation{}, scene), do: scene

  # Reproduces the client's projection exactly: elements keep first-seen order,
  # a later version replaces an earlier one, and equal versions are settled by
  # the lower nonce. Divergence here would make a snapshot disagree with a full
  # replay, which is the one thing a snapshot may never do.
  defp merge(scene, incoming) when is_list(incoming) do
    indexed =
      scene
      |> Enum.with_index()
      |> Map.new(fn {element, position} -> {element["id"], {position, element}} end)

    {merged, _next} =
      Enum.reduce(incoming, {indexed, map_size(indexed)}, fn element, {acc, next} ->
        id = element["id"]

        case Map.fetch(acc, id) do
          {:ok, {position, current}} ->
            if incoming_wins?(current, element) do
              {Map.put(acc, id, {position, element}), next}
            else
              {acc, next}
            end

          :error ->
            {Map.put(acc, id, {next, element}), next + 1}
        end
      end)

    merged
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp merge(scene, _incoming), do: scene

  defp incoming_wins?(current, incoming) do
    current_version = version(current)
    incoming_version = version(incoming)

    if incoming_version == current_version do
      nonce(incoming) < nonce(current)
    else
      incoming_version > current_version
    end
  end

  defp version(element), do: integer(Map.get(element, "version"))
  defp nonce(element), do: integer(Map.get(element, "versionNonce"))

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0
end
