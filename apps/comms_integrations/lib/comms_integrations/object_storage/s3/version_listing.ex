defmodule CommsIntegrations.ObjectStorage.S3.VersionListing do
  @moduledoc false

  @max_xml_bytes 262_144
  @entry_elements %{"Version" => :version, "DeleteMarker" => :delete_marker}
  @capture_elements %{
    "Key" => :key,
    "VersionId" => :version_id,
    "IsTruncated" => :is_truncated,
    "NextKeyMarker" => :next_key_marker,
    "NextVersionIdMarker" => :next_version_id_marker
  }

  @spec parse(binary()) ::
          {:ok,
           %{
             entries: [map()],
             truncated?: boolean(),
             next_key_marker: String.t() | nil,
             next_version_id_marker: String.t() | nil
           }}
          | {:error, atom()}
  def parse(body) when is_binary(body) and byte_size(body) <= @max_xml_bytes do
    body = String.trim_leading(body)

    if forbidden_declaration?(body) do
      {:error, :object_version_listing_invalid}
    else
      initial = %{
        capture: nil,
        capture_chunks: [],
        current: nil,
        entries: [],
        is_truncated: "false",
        next_key_marker: nil,
        next_version_id_marker: nil
      }

      case :xmerl_sax_parser.stream(body,
             event_fun: &handle_event/3,
             event_state: initial
           ) do
        {:ok, state, rest} ->
          if empty_xml_rest?(rest) do
            {:ok,
             %{
               entries: Enum.reverse(state.entries),
               truncated?: state.is_truncated == "true",
               next_key_marker: state.next_key_marker,
               next_version_id_marker: state.next_version_id_marker
             }}
          else
            {:error, :object_version_listing_invalid}
          end

        _ ->
          {:error, :object_version_listing_invalid}
      end
    end
  rescue
    _ -> {:error, :object_version_listing_invalid}
  catch
    _, _ -> {:error, :object_version_listing_invalid}
  end

  def parse(_body), do: {:error, :object_version_listing_too_large}

  defp handle_event({:startElement, _uri, local_name, _qualified_name, _attributes}, _, state) do
    name = List.to_string(local_name)

    cond do
      kind = @entry_elements[name] ->
        %{state | current: %{kind: kind, key: nil, version_id: nil}}

      field = @capture_elements[name] ->
        %{state | capture: field, capture_chunks: []}

      true ->
        state
    end
  end

  defp handle_event({:characters, characters}, _, %{capture: field} = state)
       when not is_nil(field),
       do: %{state | capture_chunks: [state.capture_chunks, characters]}

  defp handle_event({:endElement, _uri, local_name, _qualified_name}, _, state) do
    name = List.to_string(local_name)

    cond do
      Map.has_key?(@capture_elements, name) and @capture_elements[name] == state.capture ->
        value = state.capture_chunks |> IO.iodata_to_binary()

        state
        |> put_capture(state.capture, value)
        |> Map.put(:capture, nil)
        |> Map.put(:capture_chunks, [])

      Map.has_key?(@entry_elements, name) ->
        finish_entry(state)

      true ->
        state
    end
  end

  defp handle_event(_event, _location, state), do: state

  defp put_capture(%{current: current} = state, field, value)
       when field in [:key, :version_id] and is_map(current),
       do: %{state | current: Map.put(current, field, value)}

  defp put_capture(state, :is_truncated, value),
    do: %{state | is_truncated: value |> String.trim() |> String.downcase()}

  defp put_capture(state, :next_key_marker, value),
    do: %{state | next_key_marker: empty_to_nil(value)}

  defp put_capture(state, :next_version_id_marker, value),
    do: %{state | next_version_id_marker: empty_to_nil(value)}

  defp put_capture(state, _field, _value), do: state

  defp finish_entry(%{current: %{key: key, version_id: version_id} = entry} = state)
       when is_binary(key) and is_binary(version_id) and version_id != "" do
    %{state | current: nil, entries: [entry | state.entries]}
  end

  defp finish_entry(state) do
    %{state | current: nil}
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp empty_xml_rest?(rest) when is_binary(rest), do: String.trim(rest) == ""

  defp empty_xml_rest?(rest) when is_list(rest),
    do: rest |> List.to_string() |> String.trim() == ""

  defp empty_xml_rest?(_rest), do: false

  defp forbidden_declaration?(body) do
    upper = String.upcase(body)
    String.contains?(upper, "<!DOCTYPE") or String.contains?(upper, "<!ENTITY")
  end
end
