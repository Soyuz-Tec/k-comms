defmodule CommsIntegrations.Telephony.VoicemailS3 do
  @moduledoc "Server-only idempotent encrypted voicemail ingestion and version-pinned playback."
  @behaviour CommsCore.Telephony.VoicemailStoragePort.Contract
  alias CommsCore.Telephony.VoicemailObject
  alias CommsIntegrations.ObjectStorage
  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner, UploadVerifier}
  @ingest_budget_ms 30_000
  @impl true
  def ready?() do
    Application.get_env(:comms_integrations, :telephony_voicemail_storage_qualified, false) ==
      true and
      configured?()
  end

  @impl true
  def ingest(%VoicemailObject{} = object, body), do: ingest(object, body, &http/4)

  def ingest(%VoicemailObject{} = object, body, requester) do
    task =
      Task.Supervisor.async_nolink(CommsIntegrations.TaskSupervisor, fn ->
        ingest_verified(object, body, requester)
      end)

    case Task.yield(task, @ingest_budget_ms) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, :voicemail_storage_unavailable}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :voicemail_storage_unavailable}
    end
  rescue
    _ -> {:error, :voicemail_storage_unavailable}
  end

  defp ingest_verified(object, body, requester) do
    with true <- ready?() and VoicemailObject.valid?(object),
         true <-
           object.byte_size == byte_size(body) and
             object.checksum_sha256 == Base.encode16(:crypto.hash(:sha256, body), case: :lower),
         headers = %{
           "content-type" => "audio/wav",
           "if-none-match" => "*",
           "x-amz-checksum-sha256" => ObjectMetadata.checksum_base64(object.checksum_sha256),
           "x-amz-meta-sha256" => object.checksum_sha256,
           "x-amz-server-side-encryption" => "AES256"
         },
         {:ok, %{url: url, headers: signed}} <-
           Presigner.presign("PUT", object.object_key, :internal, headers, []),
         {:ok, %{status: status}} when status in 200..299 or status == 412 <-
           requester.(:put, url, Map.to_list(signed), body),
         {:ok, verified} <- UploadVerifier.verify_upload(object) do
      {:ok, struct(object, verified)}
    else
      {:error, _} -> {:error, :voicemail_storage_unavailable}
      _ -> {:error, :voicemail_storage_unavailable}
    end
  end

  @impl true
  def download(%VoicemailObject{} = object) do
    with true <- ready?() and VoicemailObject.verified?(object),
         {:ok, signed} <-
           Presigner.presign(
             "GET",
             object.object_key,
             :public,
             %{},
             [
               {"versionId", object.object_version_id},
               {"response-content-type", "audio/wav"},
               {"response-content-disposition", "inline"}
             ],
             :download
           ),
         true <- signed.development_http or URI.parse(signed.url).scheme == "https" do
      {:ok,
       Map.take(signed, [:url, :approved_origin, :development_http, :expires_at, :expires_in])
       |> Map.put(:content_type, "audio/wav")}
    else
      {:error, _} -> {:error, :voicemail_storage_unavailable}
      _ -> {:error, :voicemail_storage_unavailable}
    end
  end

  @impl true
  def delete(%VoicemailObject{} = object) do
    with true <- configured?() and VoicemailObject.valid?(object),
         {:ok, %{verified_empty?: true}} <- ObjectStorage.purge_object_versions(object) do
      :ok
    else
      {:error, _} -> {:error, :voicemail_storage_deletion_failed}
      _ -> {:error, :voicemail_storage_deletion_failed}
    end
  end

  defp configured?() do
    Application.get_env(:comms_integrations, :object_storage_adapter) ==
      CommsIntegrations.ObjectStorage.S3 and
      ObjectStorage.status().status == :available
  end

  defp http(method, url, headers, body) do
    Finch.build(method, url, headers, body)
    |> Finch.request(CommsIntegrations.Finch,
      pool_timeout: 1_000,
      request_timeout: 10_000,
      receive_timeout: 10_000
    )
  rescue
    _ -> {:error, :voicemail_storage_unavailable}
  end
end
