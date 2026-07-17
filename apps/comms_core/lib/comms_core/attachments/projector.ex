defmodule CommsCore.Attachments.Projector do
  @moduledoc false

  alias CommsCore.Attachments.{Attachment, AttachmentView, ScanAttempt, ScanAttemptView}

  def attachment(%Attachment{} = attachment) do
    %AttachmentView{
      id: attachment.id,
      tenant_id: attachment.tenant_id,
      owner_user_id: attachment.owner_user_id,
      message_id: attachment.message_id,
      object_key: attachment.object_key,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      checksum_sha256: attachment.checksum_sha256,
      object_version_id: attachment.object_version_id,
      object_etag: attachment.object_etag,
      verified_checksum_sha256: attachment.verified_checksum_sha256,
      status: attachment.status,
      scan_status: attachment.scan_status,
      scan_verdict: attachment.scan_verdict,
      scan_provider: attachment.scan_provider,
      scan_attempts: attachment.scan_attempts,
      scan_error_code: attachment.scan_error_code,
      scanned_at: attachment.scanned_at,
      quarantined_at: attachment.quarantined_at,
      scan_generation: attachment.scan_generation,
      scan_claim_token: attachment.scan_claim_token,
      scan_claimed_at: attachment.scan_claimed_at,
      uploaded_at: attachment.uploaded_at,
      inserted_at: attachment.inserted_at,
      updated_at: attachment.updated_at,
      scan_attempt_records: scan_attempts(attachment.scan_attempt_records)
    }
  end

  def attachment(nil), do: nil
  def attachments(values) when is_list(values), do: Enum.map(values, &attachment/1)

  defp scan_attempts(%Ecto.Association.NotLoaded{}), do: []
  defp scan_attempts(values) when is_list(values), do: Enum.map(values, &scan_attempt/1)
  defp scan_attempts(_), do: []

  defp scan_attempt(%ScanAttempt{} = attempt) do
    %ScanAttemptView{
      id: attempt.id,
      attachment_id: attempt.attachment_id,
      attempt_number: attempt.attempt_number,
      provider: attempt.provider,
      status: attempt.status,
      verdict: attempt.verdict,
      error_code: attempt.error_code,
      provider_reference: attempt.provider_reference,
      started_at: attempt.started_at,
      completed_at: attempt.completed_at
    }
  end
end
