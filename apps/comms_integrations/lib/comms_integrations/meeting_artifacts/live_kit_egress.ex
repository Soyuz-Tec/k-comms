defmodule CommsIntegrations.MeetingArtifacts.LiveKitEgress do
  @moduledoc "Bounded LiveKit Egress control using the approved recording destination."
  @behaviour CommsCore.AudioCalls.ArtifactProviderPort.Contract

  alias CommsCore.AudioCalls.ArtifactProviderRequest
  alias CommsIntegrations.MeetingArtifacts.{Config, EgressResponse, LiveKitWebhook}
  alias CommsIntegrations.ObjectStorage

  @timeout_ms 5_000
  @maximum_response_bytes 262_144

  # Configuration is not provider qualification or permission to record a meeting.
  def configured?(), do: match?({:ok, _}, Config.configuration())
  def authorized_adapter?(caller), do: caller == __MODULE__

  def start(request, requester \\ &request/5)

  def start(%ArtifactProviderRequest{} = command, requester) when is_function(requester, 5) do
    with :ok <- validate(command, :start),
         {:ok, config} <- Config.configuration(),
         {:ok, info} <-
           twirp(
             "StartRoomCompositeEgress",
             start_body(command, config),
             command,
             config,
             requester
           ),
         :ok <- acknowledgement_binding(info, command, config) do
      EgressResponse.receipt(info, command, :start)
    end
  end

  def start(_, _), do: {:error, :invalid_artifact_provider_request}

  def stop(request, requester \\ &request/5)

  def stop(%ArtifactProviderRequest{} = command, requester) when is_function(requester, 5) do
    with :ok <- validate(command, :stop),
         {:ok, config} <- Config.control_configuration(),
         {:ok, info} <-
           twirp("StopEgress", %{egress_id: command.provider_job_id}, command, config, requester),
         :ok <- acknowledgement_binding(info, command, config) do
      EgressResponse.receipt(info, command, :stop)
    end
  end

  def stop(_, _), do: {:error, :invalid_artifact_provider_request}

  # Start has no provider idempotency key. An uncertain start must be reconciled,
  # never retried, and adopted only when its exact room/output has one match.
  def reconcile(request, requester \\ &request/5)

  def reconcile(%ArtifactProviderRequest{} = command, requester) when is_function(requester, 5) do
    with :ok <- validate(command, :reconcile),
         {:ok, config} <- Config.control_configuration(),
         {:ok, %{"items" => items}} when is_list(items) <-
           twirp("ListEgress", %{room_name: command.provider_room}, command, config, requester) do
      matches =
        Enum.filter(items, fn info ->
          EgressResponse.matches_request?(info, command, Config.storage_output(config.storage)) and
            (is_nil(command.provider_job_id) or
               (info["egressId"] || info["egress_id"]) == command.provider_job_id)
        end)

      case matches do
        [info] -> EgressResponse.receipt(info, command, :reconcile)
        [] -> {:error, :artifact_provider_job_not_found}
        _ -> {:error, :artifact_provider_outcome_unknown}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :artifact_provider_outcome_unknown}
    end
  end

  def reconcile(_, _), do: {:error, :invalid_artifact_provider_request}

  def verify_callback(raw_body, authorization) do
    with {:ok, event} <- LiveKitWebhook.verify(raw_body, authorization) do
      EgressResponse.normalize(event)
    end
  end

  defp validate(command, operation) do
    expected_key =
      "#{command.tenant_id}/meeting-artifacts/#{command.call_id}/#{command.artifact_id}.mp4"

    with true <-
           Enum.all?(
             [command.tenant_id, command.call_id, command.artifact_id],
             &valid_segment?/1
           ),
         true <- valid_text?(command.provider_room) and valid_text?(command.operation_key),
         true <- command.content_type == "video/mp4" and command.object_key == expected_key,
         true <- operation != :stop or valid_text?(command.provider_job_id),
         true <- operation != :start or is_nil(command.provider_job_id),
         :ok <- ObjectStorage.validate_object_request(command) do
      :ok
    else
      _ -> {:error, :invalid_artifact_provider_request}
    end
  end

  defp start_body(command, config) do
    %{
      room_name: command.provider_room,
      audio_only: false,
      file_outputs: [
        %{
          file_type: "MP4",
          filepath: command.object_key,
          disable_manifest: true,
          s3: Config.storage_output(config.storage)
        }
      ]
    }
  end

  defp acknowledgement_binding(info, command, config) do
    composite = info["roomComposite"] || info["room_composite"]

    if is_nil(composite) or
         EgressResponse.matches_request?(info, command, Config.storage_output(config.storage)) do
      :ok
    else
      {:error, :artifact_provider_outcome_unknown}
    end
  end

  defp twirp(method, body, command, config, requester) do
    now = System.system_time(:second)

    claims = %{
      "iss" => config.api_key,
      "exp" => now + 30,
      "nbf" => now - 5,
      "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "video" => %{"room" => command.provider_room, "roomRecord" => true}
    }

    headers = [
      {"authorization", "Bearer " <> LiveKitWebhook.sign(claims, config.api_secret)},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    endpoint = String.trim_trailing(config.api_url, "/") <> "/twirp/livekit.Egress/" <> method
    uri = URI.parse(config.api_url)

    with {:ok, %{status: status, body: response_body}}
         when status in 200..299 and is_binary(response_body) and
                byte_size(response_body) <= @maximum_response_bytes <-
           requester.(:post, endpoint, headers, Jason.encode!(body),
             allowed_hosts: [uri.host],
             allowed_ports: [uri.port],
             timeout_ms: @timeout_ms,
             max_response_bytes: @maximum_response_bytes
           ),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(response_body) do
      {:ok, decoded}
    else
      {:ok, %{status: status}} when status in [400, 401, 403, 404, 422] ->
        {:error, :artifact_provider_unavailable}

      _ ->
        {:error, :artifact_provider_outcome_unknown}
    end
  rescue
    _ -> {:error, :artifact_provider_outcome_unknown}
  catch
    :exit, _ -> {:error, :artifact_provider_outcome_unknown}
  end

  defp request(method, url, headers, body, options) do
    uri = URI.parse(url)

    if uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
         Application.get_env(:comms_integrations, :allow_insecure_local_media, false) == true do
      Finch.request(Finch.build(method, url, headers, body), CommsIntegrations.Finch,
        pool_timeout: 1_000,
        request_timeout: @timeout_ms,
        receive_timeout: @timeout_ms
      )
    else
      CommsIntegrations.PinnedHttp.request(method, url, headers, body, options)
    end
  end

  defp valid_segment?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,254}$/, value)

  defp valid_text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..255 and String.trim(value) != "" and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, value)
end
