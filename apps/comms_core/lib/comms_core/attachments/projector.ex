defmodule CommsCore.Attachments.Projector do
  @moduledoc false

  alias CommsCore.Attachments.{
    Attachment,
    AttachmentView,
    FileView,
    ScanAttempt,
    ScanAttemptView
  }

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
      variants: project_variants(attachment.variants),
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
      upload_expires_at: attachment.upload_expires_at,
      cleanup_status: attachment.cleanup_status,
      cleanup_attempts: attachment.cleanup_attempts,
      cleanup_next_attempt_at: attachment.cleanup_next_attempt_at,
      cleanup_claimed_at: attachment.cleanup_claimed_at,
      cleanup_last_error: attachment.cleanup_last_error,
      cleanup_completed_at: attachment.cleanup_completed_at,
      inserted_at: attachment.inserted_at,
      updated_at: attachment.updated_at,
      scan_attempt_records: scan_attempts(attachment.scan_attempt_records)
    }
  end

  def attachment(nil), do: nil

  # An unloaded association is reported as absent rather than raising: a caller
  # that did not ask for variants gets an attachment without them.
  defp project_variants(%Ecto.Association.NotLoaded{}), do: []

  defp project_variants(variants) when is_list(variants) do
    Enum.map(variants, fn variant ->
      %{
        id: variant.id,
        kind: variant.kind,
        object_key: variant.object_key,
        content_type: variant.content_type,
        byte_size: variant.byte_size,
        checksum_sha256: variant.checksum_sha256,
        object_version_id: variant.object_version_id,
        uploaded_at: variant.uploaded_at
      }
    end)
  end

  defp project_variants(_variants), do: []
  def attachments(values) when is_list(values), do: Enum.map(values, &attachment/1)

  def file(%{
        attachment: %Attachment{} = attachment,
        conversation_id: conversation_id,
        conversation_sequence: conversation_sequence,
        shared_at: shared_at
      }) do
    downloadable = downloadable?(attachment)

    struct!(FileView, %{
      id: attachment.id,
      conversation_id: conversation_id,
      message_id: attachment.message_id,
      conversation_sequence: conversation_sequence,
      owner_user_id: attachment.owner_user_id,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      status: attachment.status,
      scan_status: attachment.scan_status,
      safety_state: safety_state(attachment, downloadable),
      downloadable: downloadable,
      uploaded_at: attachment.uploaded_at,
      shared_at: shared_at,
      inserted_at: attachment.inserted_at,
      updated_at: attachment.updated_at
    })
  end

  def files(values) when is_list(values), do: Enum.map(values, &file/1)

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

  defp downloadable?(%Attachment{} = attachment) do
    attachment.status == :ready and attachment.scan_status == :clean and
      is_binary(attachment.object_version_id) and attachment.object_version_id != "" and
      is_binary(attachment.object_etag) and attachment.object_etag != "" and
      is_binary(attachment.verified_checksum_sha256) and
      attachment.verified_checksum_sha256 == attachment.checksum_sha256
  end

  defp safety_state(_attachment, true), do: :available

  defp safety_state(%Attachment{status: :quarantined}, false), do: :blocked
  defp safety_state(%Attachment{scan_status: :blocked}, false), do: :blocked
  defp safety_state(%Attachment{status: :scan_failed}, false), do: :failed
  defp safety_state(%Attachment{scan_status: :failed}, false), do: :failed

  defp safety_state(%Attachment{scan_status: scan_status}, false)
       when scan_status in [:pending, :scanning],
       do: :processing

  defp safety_state(_attachment, false), do: :unavailable
end
