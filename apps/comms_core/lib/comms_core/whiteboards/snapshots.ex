defmodule CommsCore.Whiteboards.Snapshots do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo
  alias CommsCore.Whiteboards.{Operation, Scene, Snapshot}

  # How many operations may accumulate before the scene is rematerialised.
  # Small enough that a joining client never pages through much tail; large
  # enough that ordinary drawing does not rebuild on every stroke. Configurable
  # because the right value depends on write volume per board, which differs
  # between a member conversation and a public instant room.
  @default_rebuild_interval 250

  # Called only under the board row lock. Stream the current generation into a
  # bounded index; never load an entire operation history or a prior epoch.
  def prepare(_whiteboard, _generation, "board.clear", _payload) do
    {:ok, scene} = Scene.new()
    {:ok, %{scene: scene, clear?: true}}
  end

  def prepare(whiteboard, generation, "scene.update", payload) do
    existing = load(whiteboard.id)

    {base_elements, from_sequence} =
      case existing do
        %Snapshot{generation_sequence: ^generation, through_sequence: through}
        when through >= generation ->
          {elements(existing), through}

        _ ->
          {[], generation}
      end

    with {:ok, scene} <- Scene.new(base_elements),
         {:ok, scene} <- project_tail(whiteboard.id, from_sequence, whiteboard.sequence, scene),
         {:ok, scene} <- Scene.merge(scene, Map.get(payload, "elements", [])) do
      {:ok, %{scene: scene, generation: generation, existing: existing, clear?: false}}
    end
  end

  def maintain(whiteboard, sequence, %{clear?: true, scene: scene}) do
    # Clear must recover even a legacy oversized snapshot without loading it.
    existing =
      Repo.one(
        from(snapshot in Snapshot,
          where: snapshot.whiteboard_id == ^whiteboard.id,
          select: struct(snapshot, [:id])
        )
      )

    persist(whiteboard, existing, scene, sequence, sequence)
  end

  def maintain(whiteboard, sequence, prepared) do
    if due?(prepared.existing, sequence) do
      persist(whiteboard, prepared.existing, prepared.scene, sequence, prepared.generation)
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

  defp persist(whiteboard, existing, scene, sequence, generation) do
    attrs = %{
      whiteboard_id: whiteboard.id,
      tenant_id: whiteboard.tenant_id,
      conversation_id: whiteboard.conversation_id,
      through_sequence: sequence,
      generation_sequence: generation,
      elements: %{"elements" => Scene.elements(scene)}
    }

    (existing || %Snapshot{})
    |> Snapshot.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp project_tail(whiteboard_id, after_sequence, through_sequence, scene) do
    Repo.stream(
      from(operation in Operation,
        where:
          operation.whiteboard_id == ^whiteboard_id and
            operation.sequence > ^after_sequence and
            operation.sequence <= ^through_sequence,
        order_by: [asc: operation.sequence]
      ),
      max_rows: 10
    )
    |> Enum.reduce_while({:ok, scene}, fn operation, {:ok, current} ->
      case Scene.merge(current, Map.get(operation.payload, "elements", [])) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp latest_clear_sequence(whiteboard_id) do
    Repo.one(
      from(operation in Operation,
        where: operation.whiteboard_id == ^whiteboard_id and operation.kind == "board.clear",
        select: max(operation.sequence)
      )
    ) || 0
  end
end
