defmodule CommsIntegrations.MeetingArtifacts.EgressResponse do
  @moduledoc false

  alias CommsCore.AudioCalls.{ArtifactProviderReceipt, ArtifactProviderEvent}
  alias CommsIntegrations.ObjectStorage

  @events ~w(egress_updated egress_ended)

  def receipt(info, request, operation) when is_map(info) do
    with {:ok, id, room, state} <- identity(info),
         true <- room == request.provider_room,
         true <- is_nil(request.provider_job_id) or id == request.provider_job_id,
         :ok <- output_binding(info, request.object_key, state),
         {:ok, output} <- output(info, state) do
      state = if operation == :stop and state == :recording, do: :processing, else: state

      {:ok,
       %ArtifactProviderReceipt{
         provider_job_id: id,
         provider_room: room,
         object_key: request.object_key,
         byte_size: output.byte_size,
         state: state
       }}
    else
      _ -> {:error, :artifact_provider_outcome_unknown}
    end
  end

  def receipt(_, _, _), do: {:error, :artifact_provider_outcome_unknown}

  def normalize(%{"event" => event}) when event not in @events,
    do: {:error, :unsupported_provider_event}

  def normalize(event) when is_map(event) do
    info = value(event, "egressInfo", "egress_info")

    with true <- event["event"] in @events and valid_text?(event["id"]),
         true <- is_map(info),
         {:ok, id, room, state} <- identity(info),
         true <- event["event"] != "egress_ended" or state in [:available, :failed],
         {:ok, occurred_at} <- timestamp(value(event, "createdAt", "created_at")),
         {:ok, output} <- output(info, state) do
      {:ok,
       %ArtifactProviderEvent{
         event_id: event["id"],
         event_type: event["event"],
         provider_job_id: id,
         provider_room: room,
         state: state,
         object_key: output.object_key,
         byte_size: output.byte_size,
         occurred_at: occurred_at
       }}
    else
      _ -> {:error, :invalid_provider_event}
    end
  end

  def normalize(_), do: {:error, :invalid_provider_event}

  def matches_request?(info, request, approved_storage) when is_map(info) do
    composite = value(info, "roomComposite", "room_composite")

    with true <- is_map(composite),
         true <- value(info, "roomName", "room_name") == request.provider_room,
         true <- value(composite, "roomName", "room_name") == request.provider_room,
         [file] <- value(composite, "fileOutputs", "file_outputs"),
         true <- is_map(file) and file["filepath"] == request.object_key,
         true <- file["fileType"] in ["MP4", 1] or file["file_type"] in ["MP4", 1],
         storage when is_map(storage) <- file["s3"],
         true <- storage["bucket"] == approved_storage.bucket,
         true <- storage["region"] == approved_storage.region,
         true <- storage["endpoint"] == approved_storage.endpoint do
      true
    else
      _ -> false
    end
  end

  def matches_request?(_, _, _), do: false

  defp identity(info) do
    id = value(info, "egressId", "egress_id")
    room = value(info, "roomName", "room_name")

    with true <- valid_text?(id) and valid_text?(room),
         {:ok, state} <- state(Map.get(info, "status", 0)) do
      {:ok, id, room, state}
    else
      _ -> {:error, :invalid_provider_event}
    end
  end

  defp state(status) when status in [0, 1, "EGRESS_STARTING", "EGRESS_ACTIVE"],
    do: {:ok, :recording}

  defp state(status) when status in [2, "EGRESS_ENDING"], do: {:ok, :processing}
  defp state(status) when status in [3, "EGRESS_COMPLETE"], do: {:ok, :available}

  defp state(status)
       when status in [4, 5, 6, "EGRESS_FAILED", "EGRESS_ABORTED", "EGRESS_LIMIT_REACHED"],
       do: {:ok, :failed}

  defp state(_), do: {:error, :invalid_provider_event}

  defp output_binding(info, expected_key, state) do
    with {:ok, output} <- output(info, state),
         true <- is_nil(output.object_key) or output.object_key == expected_key do
      :ok
    else
      _ -> {:error, :invalid_provider_event}
    end
  end

  defp output(info, state) do
    case value(info, "fileResults", "file_results") do
      nil when state != :available -> {:ok, %{object_key: nil, byte_size: nil}}
      [] when state != :available -> {:ok, %{object_key: nil, byte_size: nil}}
      [file] when is_map(file) -> file_output(file, state)
      _ -> {:error, :invalid_provider_event}
    end
  end

  defp file_output(file, state) do
    key = file["filename"]

    with true <- valid_text?(key, 1_024),
         [tenant, "meeting-artifacts", call_id, filename] <- String.split(key, "/"),
         true <- valid_segment?(tenant) and valid_segment?(call_id),
         true <- String.ends_with?(filename, ".mp4") and valid_segment?(filename),
         :ok <- ObjectStorage.validate_object_request(%{tenant_id: tenant, object_key: key}),
         {:ok, size} <- output_size(file["size"], state) do
      {:ok, %{object_key: key, byte_size: size}}
    else
      _ -> {:error, :invalid_provider_event}
    end
  end

  defp timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> timestamp(seconds)
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp(value) when is_integer(value) and value >= 0, do: DateTime.from_unix(value)
  defp timestamp(_), do: {:error, :invalid_timestamp}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_size}
    end
  end

  defp positive_integer(_), do: {:error, :invalid_size}

  defp output_size(size, state) when size in [nil, 0, "0"] and state != :available,
    do: {:ok, nil}

  defp output_size(size, _state), do: positive_integer(size)
  defp valid_segment?(value), do: Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,254}$/, value)

  defp valid_text?(value, limit \\ 255),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.trim(value) != "" and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, value)

  defp value(map, camel, snake), do: Map.get(map, camel) || Map.get(map, snake)
end
