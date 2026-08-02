defmodule CommsCore.Messaging.MessageMetadata do
  @moduledoc false

  @max_links 5
  @max_reference_elements 20
  @coordinate_limit 10_000_000

  def validate(metadata) when is_map(metadata) do
    with :ok <- validate_whiteboard_reference(value(metadata, "whiteboard_reference")),
         :ok <- validate_links(value(metadata, "links")) do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_message_metadata}

  defp validate_whiteboard_reference(nil), do: :ok

  defp validate_whiteboard_reference(reference) when is_map(reference) do
    element_ids = value(reference, "element_ids") || []
    region = value(reference, "region")
    sequence = value(reference, "board_sequence")
    label = value(reference, "label")

    cond do
      not is_list(element_ids) ->
        {:error, :invalid_whiteboard_reference}

      length(element_ids) > @max_reference_elements ->
        {:error, :too_many_whiteboard_elements}

      Enum.any?(element_ids, &(not valid_element_id?(&1))) ->
        {:error, :invalid_whiteboard_reference}

      length(Enum.uniq(element_ids)) != length(element_ids) ->
        {:error, :invalid_whiteboard_reference}

      region != nil and not valid_region?(region) ->
        {:error, :invalid_whiteboard_reference}

      element_ids == [] and region == nil ->
        {:error, :invalid_whiteboard_reference}

      sequence != nil and (not is_integer(sequence) or sequence < 0) ->
        {:error, :invalid_whiteboard_reference}

      label != nil and (not is_binary(label) or String.length(String.trim(label)) not in 1..120) ->
        {:error, :invalid_whiteboard_reference}

      true ->
        :ok
    end
  end

  defp validate_whiteboard_reference(_), do: {:error, :invalid_whiteboard_reference}

  defp validate_links(nil), do: :ok

  defp validate_links(links) when is_list(links) do
    cond do
      length(links) > @max_links -> {:error, :too_many_message_links}
      Enum.all?(links, &valid_link?/1) -> :ok
      true -> {:error, :invalid_message_link}
    end
  end

  defp validate_links(_), do: {:error, :invalid_message_link}

  defp valid_link?(link) when is_map(link) do
    url = value(link, "url")
    label = value(link, "label") || value(link, "title")

    case URI.parse(if(is_binary(url), do: String.trim(url), else: "")) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: fragment}
      when is_binary(host) and byte_size(host) > 0 ->
        byte_size(url) <= 2_048 and
          (is_nil(fragment) or byte_size(fragment) <= 512) and
          (is_nil(label) or (is_binary(label) and String.length(String.trim(label)) in 1..160))

      _ ->
        false
    end
  end

  defp valid_link?(_), do: false

  defp valid_element_id?(id), do: is_binary(id) and byte_size(id) in 8..128

  defp valid_region?(region) when is_map(region) do
    x = value(region, "x")
    y = value(region, "y")
    width = value(region, "width")
    height = value(region, "height")

    finite_coordinate?(x) and finite_coordinate?(y) and positive_extent?(width) and
      positive_extent?(height)
  end

  defp valid_region?(_), do: false

  defp finite_coordinate?(value),
    do: is_number(value) and value >= -@coordinate_limit and value <= @coordinate_limit

  defp positive_extent?(value),
    do: is_number(value) and value > 0 and value <= @coordinate_limit

  defp value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
