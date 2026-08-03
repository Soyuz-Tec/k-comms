defmodule CommsWeb.Presenters.ConversationContent do
  @moduledoc false

  alias CommsCore.Attachments.{AttachmentView, FileView}
  alias CommsCore.Messaging.{MessageView, ReactionView}
  alias CommsCore.Whiteboards.OperationView

  def message(%MessageView{} = message) do
    %{
      id: message.id,
      tenant_id: message.tenant_id,
      conversation_id: message.conversation_id,
      sender_user_id: message.sender_user_id,
      sender_device_id: message.sender_device_id,
      reply_to_message_id: message.reply_to_message_id,
      thread_root_message_id: message.thread_root_message_id,
      thread_reply_count: message.thread_reply_count || 0,
      mentioned_user_ids: message.mentioned_user_ids,
      client_message_id: message.client_message_id,
      conversation_sequence: message.conversation_sequence,
      body: message.body,
      metadata: message.metadata || %{},
      status: message.status,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at,
      attachments: Enum.map(message.attachments, &attachment/1),
      reactions: Enum.map(message.reactions, &reaction/1)
    }
  end

  def attachment(%AttachmentView{} = attachment) do
    %{
      id: attachment.id,
      message_id: attachment.message_id,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      checksum_sha256: attachment.checksum_sha256,
      status: attachment.status,
      uploaded_at: attachment.uploaded_at,
      scan_status: attachment.scan_status,
      scan_verdict: attachment.scan_verdict,
      scan_provider: attachment.scan_provider,
      scan_attempts: attachment.scan_attempts,
      scan_error_code: attachment.scan_error_code,
      scanned_at: attachment.scanned_at,
      quarantined_at: attachment.quarantined_at,
      variant_kinds: verified_variant_kinds(attachment)
    }
  end

  def file(%FileView{} = file) do
    %{
      id: file.id,
      conversation_id: file.conversation_id,
      message_id: file.message_id,
      conversation_sequence: file.conversation_sequence,
      owner_user_id: file.owner_user_id,
      file_name: file.file_name,
      content_type: file.content_type,
      byte_size: file.byte_size,
      status: file.status,
      scan_status: file.scan_status,
      safety_state: file.safety_state,
      downloadable: file.downloadable,
      uploaded_at: file.uploaded_at,
      shared_at: file.shared_at,
      inserted_at: file.inserted_at,
      updated_at: file.updated_at
    }
  end

  def whiteboard_operation(%OperationView{} = operation) do
    %{
      id: operation.id,
      whiteboard_id: operation.whiteboard_id,
      tenant_id: operation.tenant_id,
      conversation_id: operation.conversation_id,
      actor_user_id: operation.actor_user_id,
      client_operation_id: operation.client_operation_id,
      sequence: operation.sequence,
      kind: operation.kind,
      payload: operation.payload,
      inserted_at: operation.inserted_at
    }
  end

  @doc """
  Presents a materialised scene, or `nil` when the caller must replay instead.

  Deliberately not shaped like an operation: it carries no actor and no
  idempotency key, because it is a projection rather than something anybody did.
  """
  def whiteboard_snapshot(nil), do: nil

  def whiteboard_snapshot(%{elements: elements, through_sequence: through_sequence}) do
    %{elements: elements, through_sequence: through_sequence}
  end

  defp verified_variant_kinds(%AttachmentView{variants: variants}) when is_list(variants) do
    variants
    |> Enum.filter(&is_binary(Map.get(&1, :object_version_id)))
    |> Enum.map(&Map.get(&1, :kind))
  end

  defp verified_variant_kinds(_attachment), do: []

  defp reaction(%ReactionView{} = reaction) do
    %{id: reaction.id, user_id: reaction.user_id, emoji: reaction.emoji}
  end
end
