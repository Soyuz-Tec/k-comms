defmodule CommsWorkers.AttachmentWorker do
  use Oban.Worker, queue: :media, max_attempts: 5

  alias CommsCore.Attachments
  alias CommsCore.Attachments.Attachment
  alias CommsIntegrations.{ObjectStorage, Scanner}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attachment_id" => attachment_id}}) do
    case Attachments.claim_scan(attachment_id) do
      {:ok, {:already_clean, _attachment}} ->
        :ok

      {:ok, %Attachment{} = attachment} ->
        result = scan(attachment)

        case Attachments.record_scan(attachment, result) do
          {:ok, _updated} -> worker_result(result)
          {:error, :stale_scan_claim} -> :ok
          {:error, reason} -> {:error, safe_reason(reason)}
        end

      {:error, :not_found} ->
        {:discard, :attachment_not_found}

      {:error, :not_claimable} ->
        {:snooze, 30}

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_), do: {:discard, :attachment_id_required}

  defp scan(attachment) do
    with {:ok, download} <- ObjectStorage.presign_download(attachment) do
      Scanner.scan(%{
        tenant_id: attachment.tenant_id,
        attachment_id: attachment.id,
        object_key: attachment.object_key,
        content_type: attachment.content_type,
        byte_size: attachment.byte_size,
        checksum_sha256: attachment.checksum_sha256,
        download: download
      })
      |> validate_verdict()
    end
  end

  defp validate_verdict({:ok, metadata} = result) when is_map(metadata) do
    case Map.get(metadata, :verdict) || Map.get(metadata, "verdict") do
      verdict
      when verdict in [
             :clean,
             "clean",
             :malicious,
             "malicious",
             :suspicious,
             "suspicious",
             :blocked,
             "blocked"
           ] ->
        result

      _ ->
        {:error, :invalid_scanner_response}
    end
  end

  defp validate_verdict(result), do: result

  defp worker_result({:ok, _}), do: :ok
  defp worker_result({:error, :permanent, reason}), do: {:discard, safe_reason(reason)}
  defp worker_result({:error, reason}), do: {:error, safe_reason(reason)}
  defp worker_result(_), do: {:error, :invalid_scanner_response}
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, status}) when is_atom(kind) and is_integer(status), do: {kind, status}
  defp safe_reason(_), do: :scanner_error
end
