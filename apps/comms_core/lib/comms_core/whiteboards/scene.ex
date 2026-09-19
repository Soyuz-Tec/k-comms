defmodule CommsCore.Whiteboards.Scene do
  @moduledoc false

  # Tombstones count too: dropping them would let an old client resurrect data.
  @maximum_elements 5_000
  @maximum_bytes 2 * 1024 * 1024
  @empty_bytes byte_size(~s({"elements":[]}))

  defstruct entries: %{}, element_bytes: 0

  def new(elements \\ []) do
    Enum.reduce_while(elements, {:ok, %__MODULE__{}}, fn element, {:ok, scene} ->
      case merge(scene, [element]) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def merge(%__MODULE__{} = scene, elements) when is_list(elements) do
    merged = Enum.reduce(elements, scene, &put/2)
    count = map_size(merged.entries)
    bytes = @empty_bytes + merged.element_bytes + max(count - 1, 0)

    if count <= @maximum_elements and bytes <= @maximum_bytes,
      do: {:ok, merged},
      else: {:error, :whiteboard_capacity_exceeded}
  end

  def elements(%__MODULE__{entries: entries}) do
    entries
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp put(element, scene) do
    id = element["id"]

    case Map.fetch(scene.entries, id) do
      {:ok, {position, current, bytes}} ->
        if incoming_wins?(current, element),
          do: replace(scene, id, position, element, bytes),
          else: scene

      :error ->
        replace(scene, id, map_size(scene.entries), element, 0)
    end
  end

  defp replace(scene, id, position, element, old_bytes) do
    bytes = byte_size(Jason.encode!(element))

    %{
      scene
      | entries: Map.put(scene.entries, id, {position, element, bytes}),
        element_bytes: scene.element_bytes - old_bytes + bytes
    }
  end

  defp incoming_wins?(current, incoming) do
    current_version = integer(current["version"])
    incoming_version = integer(incoming["version"])

    if incoming_version == current_version,
      do: integer(incoming["versionNonce"]) < integer(current["versionNonce"]),
      else: incoming_version > current_version
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0
end
