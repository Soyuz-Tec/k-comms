defmodule CommsIntegrations.MeetingArtifacts.WhisperTranscription do
  @behaviour CommsCore.AudioCalls.ArtifactTranscriptionPort.Contract
  @moduledoc "Transcribes a verified recording through an explicitly qualified Whisper HTTPS origin."

  alias CommsCore.AudioCalls.{ArtifactStorageObject, ArtifactTranscriptionRequest}
  alias CommsIntegrations.MeetingArtifacts.{SourceMedia, TranscriptResponse, TranscriptionConfig}
  alias CommsIntegrations.ObjectStorage
  alias CommsIntegrations.ObjectStorage.S3.ObjectMetadata

  def configured?(), do: match?({:ok, _}, TranscriptionConfig.configuration())
  def authorized_adapter?(caller), do: caller == __MODULE__

  def transcribe(command, requester \\ &request/5, fetcher \\ &SourceMedia.fetch/2)

  def transcribe(%ArtifactTranscriptionRequest{} = command, requester, fetcher)
      when is_function(requester, 5) and is_function(fetcher, 2) do
    with {:ok, config} <- TranscriptionConfig.configuration(),
         :ok <- validate(command, config),
         {:ok, media} when is_binary(media) <- fetcher.(command.object, config),
         true <- byte_size(media) == command.object.byte_size,
         true <-
           Base.encode16(:crypto.hash(:sha256, media), case: :lower) ==
             String.downcase(command.object.verified_checksum_sha256),
         {:ok, response} <- submit(media, config, requester) do
      with {:ok, transcript} <- TranscriptResponse.normalize(response),
           :ok <- verify_recognition_proof(response, command, config) do
        if config.model_sha256 do
          {:ok,
           %{
             transcript
             | provider_id: response["id"],
               model_sha256: response["model_sha256"],
               source_sha256: response["source_sha256"]
           }}
        else
          {:ok, transcript}
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :artifact_source_media_unavailable}
    end
  rescue
    _ -> {:error, :artifact_transcription_unavailable}
  catch
    :exit, _ -> {:error, :artifact_transcription_unavailable}
  end

  def transcribe(_, _, _), do: {:error, :invalid_artifact_transcription_request}

  defp validate(%{object: %ArtifactStorageObject{} = object} = command, config) do
    with true <-
           Enum.all?(
             [command.tenant_id, command.artifact_id, command.source_artifact_id],
             &valid_id?/1
           ),
         true <- command.tenant_id == object.tenant_id and object.content_type == "video/mp4",
         :ok <- ObjectStorage.validate_object_request(object),
         [tenant, "meeting-artifacts", call_id, filename] <- String.split(object.object_key, "/"),
         true <- tenant == command.tenant_id and valid_id?(call_id),
         true <- filename == command.source_artifact_id <> ".mp4",
         {:ok, _} <- ObjectMetadata.required_version(object),
         {:ok, _} <- ObjectMetadata.required_verified_checksum(object),
         {:ok, size} <- ObjectMetadata.required_size(object),
         true <- size <= config.max_media_bytes do
      :ok
    else
      _ -> {:error, :invalid_artifact_transcription_request}
    end
  end

  defp validate(_, _), do: {:error, :invalid_artifact_transcription_request}

  defp submit(media, config, requester) do
    boundary = "kc-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    fields = [{"model", config.model}, {"response_format", "verbose_json"}]

    fields =
      if is_nil(config.language), do: fields, else: fields ++ [{"language", config.language}]

    body =
      [
        Enum.map(fields, fn {name, value} ->
          [
            "--",
            boundary,
            "\r\nContent-Disposition: form-data; name=\"",
            name,
            "\"\r\n\r\n",
            value,
            "\r\n"
          ]
        end),
        "--",
        boundary,
        "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.mp4\"\r\nContent-Type: video/mp4\r\n\r\n",
        media,
        "\r\n--",
        boundary,
        "--\r\n"
      ]
      |> IO.iodata_to_binary()

    headers = [
      {"content-type", "multipart/form-data; boundary=" <> boundary},
      {"accept", "application/json"}
    ]

    headers =
      if config.bearer_token,
        do: [{"authorization", "Bearer " <> config.bearer_token} | headers],
        else: headers

    uri = URI.parse(config.origin)

    with {:ok, %{status: status, body: response}}
         when status in 200..299 and is_binary(response) and
                byte_size(response) <= config.max_response_bytes <-
           requester.(:post, config.origin <> "/v1/audio/transcriptions", headers, body,
             allowed_hosts: [uri.host],
             allowed_ports: [uri.port],
             timeout_ms: config.timeout_ms,
             max_response_bytes: config.max_response_bytes
           ),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(response) do
      {:ok, decoded}
    else
      _ -> {:error, :artifact_transcription_unavailable}
    end
  end

  defp verify_recognition_proof(response, command, %{model_sha256: expected})
       when is_binary(expected) do
    id = response["id"]

    if response["model_sha256"] == expected and
         response["source_sha256"] == command.object.verified_checksum_sha256 and
         is_binary(id) and byte_size(id) in 1..200 and response["mode"] == "post_recording",
       do: :ok,
       else: {:error, :invalid_artifact_transcript}
  end

  defp verify_recognition_proof(_, _, _), do: :ok

  defp request(method, url, headers, body, options),
    do: CommsIntegrations.PinnedHttp.request(method, url, headers, body, options)

  defp valid_id?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,254}$/, value)
end
