defmodule CommsCore.Whiteboards.Payload do
  @moduledoc false

  @maximum_elements_per_update 200
  @maximum_encoded_bytes 512_000
  @maximum_element_bytes 64_000
  @allowed_types ~w(rectangle diamond ellipse line arrow freedraw text frame image)

  @spec validate(String.t(), map()) :: {:ok, map()} | {:error, :invalid_whiteboard_operation}
  def validate("scene.update", payload) when is_map(payload) do
    elements = value(payload, "elements")

    with true <- is_list(elements),
         true <- length(elements) in 1..@maximum_elements_per_update,
         {:ok, normalized} <- normalize_elements(elements),
         {:ok, encoded} <- Jason.encode(%{"elements" => normalized}),
         true <- byte_size(encoded) <= @maximum_encoded_bytes do
      {:ok, %{"elements" => normalized}}
    else
      _ -> {:error, :invalid_whiteboard_operation}
    end
  end

  def validate("board.clear", payload) when is_map(payload) and map_size(payload) == 0,
    do: {:ok, %{}}

  def validate(_, _), do: {:error, :invalid_whiteboard_operation}

  # A valid 2 MiB scene may contain fewer than 200 large elements. Restores
  # must respect both operation bounds, not only the element count.
  def chunk_elements(elements) do
    overhead = byte_size(Jason.encode!(%{"elements" => []}))

    {chunks, current, _count, _bytes} =
      Enum.reduce(elements, {[], [], 0, overhead}, fn element, {chunks, current, count, bytes} ->
        element_bytes = byte_size(Jason.encode!(element))
        next_bytes = bytes + element_bytes + if(count > 0, do: 1, else: 0)

        if count == @maximum_elements_per_update or next_bytes > @maximum_encoded_bytes do
          {[Enum.reverse(current) | chunks], [element], 1, overhead + element_bytes}
        else
          {chunks, [element | current], count + 1, next_bytes}
        end
      end)

    if current == [],
      do: Enum.reverse(chunks),
      else: Enum.reverse([Enum.reverse(current) | chunks])
  end

  defp normalize_elements(elements) do
    Enum.reduce_while(elements, {:ok, []}, fn element, {:ok, acc} ->
      case normalize_element(element) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp normalize_element(element) when is_map(element) do
    with {:ok, id} <- identifier(value(element, "id")),
         type when type in @allowed_types <- value(element, "type"),
         version when is_integer(version) and version > 0 <- value(element, "version"),
         version_nonce when is_integer(version_nonce) <- value(element, "versionNonce"),
         nil <- value(element, "link"),
         nil <- value(element, "customData"),
         true <- valid_image_reference?(type, element) do
      normalized =
        element
        |> stringify_keys()
        |> Map.put("id", id)
        |> Map.put("type", type)
        |> Map.put("version", version)
        |> Map.put("versionNonce", version_nonce)
        |> Map.put("link", nil)
        |> Map.put("customData", nil)

      case Jason.encode(normalized) do
        {:ok, encoded} when byte_size(encoded) <= @maximum_element_bytes -> {:ok, normalized}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp normalize_element(_), do: :error

  defp valid_image_reference?("image", element) do
    match?({:ok, _}, Ecto.UUID.cast(value(element, "fileId"))) and
      value(element, "dataURL") == nil and value(element, "src") == nil and
      value(element, "url") == nil
  end

  defp valid_image_reference?(_, _), do: true

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp identifier(value) when is_binary(value) do
    trimmed = String.trim(value)
    if byte_size(trimmed) in 8..128, do: {:ok, trimmed}, else: :error
  end

  defp identifier(_), do: :error
  defp value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
