defmodule CommsWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]
  alias CommsCore.ValidationError

  def call(conn, {:error, %ValidationError{details: details}}) do
    render_error(conn, 422, "validation_failed", "The request is invalid", details)
  end

  def call(conn, {:error, {:missing_fields, fields}}) do
    render_error(conn, 422, "missing_fields", "Required fields are missing", %{fields: fields})
  end

  def call(conn, {:error, reason}) do
    case ValidationError.from(reason) do
      {:ok, error} ->
        call(conn, {:error, error})

      :error ->
        {status, code, detail} = error(reason)
        render_error(conn, status, code, detail)
    end
  end

  defp error(reason)
       when reason in [:invalid_credentials, :invalid_refresh_token, :invalid_access_token],
       do: {401, "unauthenticated", "Authentication failed"}

  defp error(:forbidden), do: {403, "forbidden", "This operation is not permitted"}

  defp error(:platform_role_console_only),
    do: {403, "platform_role_console_only", "Platform roles are managed outside tenant APIs"}

  defp error(:not_found), do: {404, "not_found", "The requested resource was not found"}

  defp error(:invalid_password_recovery_token),
    do: {400, "invalid_recovery_token", "The recovery token is invalid or expired"}

  defp error(:version_required),
    do: {428, "version_required", "The current resource version is required"}

  defp error(:stale_version),
    do: {409, "stale_version", "The resource changed; reload it before retrying"}

  defp error(:step_up_required),
    do: {428, "step_up_required", "Recent password verification is required"}

  defp error(:email_change_requires_verification),
    do:
      {409, "email_change_requires_verification",
       "Changing the recovery email requires a verified email-change workflow"}

  defp error(:public_channels_disabled),
    do: {403, "public_channels_disabled", "Tenant-visible channels are disabled"}

  defp error(:audio_calls_disabled),
    do: {403, "audio_calls_disabled", "Audio calls are disabled for this tenant"}

  defp error(:video_calls_disabled),
    do: {403, "video_calls_disabled", "Video calls are disabled for this tenant"}

  defp error(reason)
       when reason in [
              :conflict,
              :last_owner_required,
              :conversation_archived,
              :invitation_not_pending,
              :invitation_identity_conflict,
              :legal_hold_not_active,
              :legal_hold_active,
              :invalid_status_transition,
              :already_delivered,
              :already_clean,
              :endpoint_disabled,
              :not_claimable,
              :direct_membership_immutable,
              :deletion_in_progress,
              :deletion_evidence_mismatch,
              :edit_window_expired,
              :push_subscription_conflict,
              :push_subscription_limit_reached,
              :push_subscription_terminal,
              :audio_call_ended,
              :audio_call_ending,
              :audio_call_expired,
              :call_media_kind_conflict
            ],
       do:
         {409, Atom.to_string(reason), "The operation conflicts with the current resource state"}

  defp error(reason) when reason in [:invalid_invitation, :invalid_current_password],
    do: {401, "authentication_failed", "Authentication failed"}

  defp error(:conversation_not_found),
    do: {404, "conversation_not_found", "The conversation was not found"}

  defp error(:attachment_not_ready),
    do: {409, "attachment_not_ready", "The attachment is not ready"}

  defp error(:attachment_not_pending),
    do: {409, "attachment_not_pending", "The attachment is not pending"}

  defp error(:object_not_found),
    do: {409, "object_not_found", "The uploaded object was not found"}

  defp error(:object_size_mismatch),
    do: {422, "object_size_mismatch", "The uploaded object size does not match"}

  defp error(:object_checksum_mismatch),
    do: {422, "object_checksum_mismatch", "The uploaded object checksum metadata does not match"}

  defp error(reason)
       when reason in [
              :secret_encryption_key_not_configured,
              :object_storage_adapter_not_configured,
              :notification_adapter_not_configured,
              :webhook_adapter_not_configured,
              :scanner_adapter_not_configured,
              :provider_unavailable,
              :object_versioning_required,
              :object_version_unavailable,
              :object_etag_unavailable,
              :object_checksum_unavailable,
              :outbound_dns_unavailable,
              :password_recovery_unavailable,
              :push_subscriptions_unavailable,
              :notification_delivery_unavailable,
              :push_subscription_encryption_key_not_configured,
              :current_push_subscription_key_not_configured,
              :invalid_push_subscription_encryption_key,
              :invalid_web_push_vapid_public_key,
              :audio_provider_unavailable
            ],
       do: {503, "provider_unavailable", "A required external provider is unavailable"}

  defp error(:direct_conversation_exists),
    do: {409, "conversation_exists", "The direct conversation already exists"}

  defp error(:cannot_remove_owner),
    do: {409, "cannot_remove_owner", "The conversation owner cannot be removed"}

  defp error(:active_user_quota_exceeded),
    do: {409, "active_user_quota_exceeded", "The tenant active-identity limit has been reached"}

  defp error(:active_conversation_quota_exceeded),
    do:
      {409, "active_conversation_quota_exceeded",
       "The tenant active-conversation limit has been reached"}

  defp error(:conversation_member_quota_exceeded),
    do:
      {409, "conversation_member_quota_exceeded",
       "The conversation active-membership limit has been reached"}

  defp error(:quota_transaction_required),
    do: {500, "quota_boundary_error", "The admission boundary was not available"}

  defp error(reason)
       when reason in [
              :weak_password,
              :invalid_members,
              :direct_conversation_requires_two_members,
              :identity_mismatch,
              :message_body_required,
              :message_too_large,
              :too_many_attachments,
              :duplicate_attachment_ids,
              :invalid_attachment_id,
              :metadata_too_many_properties,
              :metadata_too_large,
              :invalid_reply_target,
              :invalid_mentions,
              :invalid_mention_id,
              :too_many_mentions,
              :invalid_message_body,
              :idempotency_key_required,
              :invalid_idempotency_key,
              :invalid_sequence,
              :invalid_search_query,
              :search_query_required,
              :unsupported_content_type,
              :invalid_attachment_size,
              :invalid_attachment_checksum,
              :attachment_checksum_mismatch,
              :invalid_attachments,
              :invalid_role,
              :invalid_status,
              :invalid_datetime,
              :invalid_cursor,
              :invalid_moderation_target,
              :invalid_moderation_action,
              :invalid_assignee,
              :invalid_governance_target,
              :completion_evidence_required,
              :reason_required,
              :invalid_webhook_destination,
              :webhook_event_types_required,
              :invalid_webhook_event_type,
              :too_many_webhook_event_types,
              :invalid_push_subscription,
              :invalid_push_endpoint,
              :invalid_push_p256dh_key,
              :invalid_push_auth_key,
              :invalid_push_expiration,
              :unsupported_operation,
              :invalid_end_reason,
              :invalid_media_kind,
              :audio_identity_invalid
            ],
       do: {422, Atom.to_string(reason), "The request could not be processed"}

  defp error(_), do: {500, "internal_error", "The request could not be completed"}

  defp render_error(conn, status, code, detail, meta \\ nil) do
    error = %{code: code, detail: detail}
    error = if is_nil(meta), do: error, else: Map.put(error, :meta, meta)

    conn
    |> put_status(status)
    |> json(%{error: error})
  end
end
