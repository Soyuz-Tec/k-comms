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

  defp error(reason)
       when reason in [:calendar_legal_hold, :calendar_export_blocked, :calendar_export_disabled],
       do:
         {403, Atom.to_string(reason), "Calendar export is unavailable under the current policy"}

  defp error(reason)
       when reason in [
              :calendar_cleanup_pending,
              :calendar_export_terminal,
              :calendar_occurrence_terminal,
              :calendar_cleanup_principal_mismatch
            ],
       do:
         {409, Atom.to_string(reason),
          "Calendar cleanup is pending or the source changed. Reload its status"}

  defp error(reason)
       when reason in [
              :invalid_calendar_provider,
              :invalid_calendar_purpose,
              :invalid_calendar_decision,
              :invalid_meeting_id
            ],
       do: {422, Atom.to_string(reason), "Choose a valid calendar provider and explicit action"}

  defp error(reason)
       when reason in [
              :calendar_provider_not_configured,
              :calendar_worker_unavailable,
              :calendar_protection_unavailable,
              :calendar_secret_keyring_not_configured
            ],
       do:
         {503, Atom.to_string(reason),
          "Calendar synchronization is not configured for this deployment"}

  defp error(reason) when reason in [:invalid_mfa_code, :invalid_mfa_challenge],
    do: {401, Atom.to_string(reason), "The authenticator or recovery code is invalid or expired"}

  defp error(:mfa_rate_limited),
    do: {429, "mfa_rate_limited", "Too many verification attempts. Try again later"}

  defp error(:mfa_required),
    do: {428, "mfa_required", "An authenticator or unused recovery code is required"}

  defp error(:oidc_not_configured),
    do: {503, "oidc_not_configured", "Corporate sign in is not configured for this deployment"}

  defp error(reason)
       when reason in [:invalid_oidc_state, :invalid_oidc_token, :invalid_oidc_response],
       do:
         {401, Atom.to_string(reason),
          "Corporate identity verification failed. Start sign in again"}

  defp error(:federated_identity_not_linked),
    do:
      {403, "federated_identity_not_linked",
       "Link corporate sign in in account security or ask your administrator to provision it"}

  defp error(reason)
       when reason in [
              :mfa_already_enabled,
              :mfa_enrollment_expired,
              :federated_identity_conflict
            ],
       do:
         {409, Atom.to_string(reason), "Account security changed. Reload and retry verification"}

  defp error(:mfa_enrollment_required),
    do: {428, "mfa_enrollment_required", "Begin authenticator setup before confirming it"}

  defp error(:oidc_recent_authentication_required),
    do: {428, "oidc_recent_authentication_required", "Verify your corporate session again"}

  defp error(:invalid_break_glass_credentials),
    do: {401, "unauthenticated", "Emergency identity verification failed"}

  defp error(reason) when reason in [:invalid_availability, :invalid_availability_channel],
    do: {422, Atom.to_string(reason), "Choose a valid availability state, timezone, and schedule"}

  defp error(reason)
       when reason in [
              :oidc_provider_unavailable,
              :invalid_oidc_discovery,
              :identity_secret_encryption_key_not_configured,
              :identity_secret_decryption_failed,
              :identity_secret_encryption_key_unavailable,
              :current_identity_secret_key_not_configured,
              :invalid_identity_secret_encryption_key,
              :invalid_identity_secret_encryption_key_id
            ],
       do:
         {503, Atom.to_string(reason), "Account security verification is temporarily unavailable"}

  defp error(:meeting_guests_disabled),
    do: {403, "meeting_guests_disabled", "Guests are disabled for this meeting"}

  defp error(:meeting_erasure_pending),
    do:
      {409, "meeting_erasure_pending",
       "This meeting is unavailable while deletion is in progress"}

  defp error(:meeting_authorship_unavailable),
    do:
      {503, "meeting_authorship_unavailable",
       "Meeting history verification is temporarily unavailable"}

  defp error(:meeting_legal_hold),
    do: {409, "meeting_legal_hold", "A preservation hold prevents this change"}

  defp error(:recording_consent_admission_blocked),
    do:
      {409, "recording_consent_admission_blocked",
       "Recording must stop before a new participant can join"}

  defp error(reason)
       when reason in [
              :meeting_cancelled,
              :meeting_already_started,
              :meeting_not_joinable,
              :meeting_host_required
            ],
       do: {409, Atom.to_string(reason), "This meeting cannot be joined in its current state"}

  defp error(reason)
       when reason in [
              :invalid_meeting,
              :invalid_meeting_range,
              :invalid_meeting_timezone,
              :invalid_meeting_recurrence,
              :invalid_meeting_host_policy,
              :ambiguous_meeting_time,
              :nonexistent_meeting_time
            ],
       do: {422, Atom.to_string(reason), "The meeting schedule is invalid"}

  defp error(:platform_role_console_only),
    do: {403, "platform_role_console_only", "Platform roles are managed outside tenant APIs"}

  defp error(:not_found), do: {404, "not_found", "The requested resource was not found"}

  defp error(:contact_unavailable),
    do: {409, "contact_unavailable", "A selected person is no longer available in this workspace"}

  defp error(reason) when reason in [:invalid_member_workspace, :invalid_onboarding_action],
    do: {422, Atom.to_string(reason), "The private workspace update is invalid"}

  defp error(reason)
       when reason in [
              :invalid_guest_link,
              :guest_link_unavailable,
              :guest_link_not_found,
              :guest_link_expired,
              :guest_link_revoked,
              :guest_link_exhausted,
              :guest_admission_expired
            ],
       do: {404, "guest_link_unavailable", "This guest communication link is unavailable"}

  defp error(reason)
       when reason in [
              :ephemeral_room_unavailable,
              :ephemeral_room_not_found,
              :instant_room_unavailable,
              :ephemeral_room_expired,
              :ephemeral_room_revoked
            ],
       do: {404, "instant_room_unavailable", "This instant communication room is unavailable"}

  defp error(reason)
       when reason in [:invalid_guest_access_token, :guest_session_expired],
       do: {401, "unauthenticated", "Guest authentication failed"}

  defp error(:invalid_password_recovery_token),
    do: {400, "invalid_recovery_token", "The recovery token is invalid or expired"}

  defp error(:version_required),
    do: {428, "version_required", "The current resource version is required"}

  defp error(:stale_version),
    do: {409, "stale_version", "The resource changed; reload it before retrying"}

  defp error(reason)
       when reason in [:stale_draft, :stale_board_version],
       do:
         {409, Atom.to_string(reason),
          "This content changed on another device. Reload before retrying"}

  defp error(reason)
       when reason in [
              :draft_capacity,
              :saved_item_capacity,
              :whiteboard_version_capacity,
              :whiteboard_asset_capacity
            ],
       do: {409, Atom.to_string(reason), "This content collection has reached its capacity"}

  defp error(reason)
       when reason in [:invalid_draft, :invalid_board_title, :asset_unavailable],
       do: {422, Atom.to_string(reason), "Use valid content and an approved available asset"}

  defp error(:stale_whiteboard_generation),
    do:
      {409, "stale_whiteboard_generation",
       "The whiteboard was cleared after this edit began; reload before retrying"}

  defp error(:step_up_required),
    do: {428, "step_up_required", "Recent identity verification is required"}

  defp error(:invalid_provider_webhook),
    do: {401, "invalid_provider_webhook", "A valid provider signature is required"}

  defp error(:telephony_disabled),
    do: {503, "telephony_disabled", "Telephone calling is unavailable"}

  defp error(:telephony_provider_unavailable),
    do: {503, "provider_unavailable", "The telephone provider is unavailable"}

  defp error(:invalid_provider_event),
    do: {422, "invalid_provider_event", "The provider event could not be processed"}

  defp error(:telephony_not_configured),
    do: {409, "telephony_not_configured", "A telephone line must be assigned before calling"}

  defp error(reason)
       when reason in [
              :invalid_telephony_command,
              :invalid_telephony_route,
              :invalid_telephony_mailbox,
              :invalid_voicemail_limit,
              :invalid_voicemail_cursor,
              :invalid_voicemail_media,
              :voicemail_storage_identity_invalid
            ],
       do: {422, Atom.to_string(reason), "Use valid telephone controls and mailbox settings"}

  defp error(reason)
       when reason in [
              :telephony_control_conflict,
              :recipient_unavailable,
              :voicemail_capture_cancelled,
              :voicemail_provider_identity_invalid,
              :voicemail_legal_hold,
              :voicemail_not_deletable,
              :voicemail_already_deleted,
              :telephony_mailbox_full,
              :telephony_mailbox_unavailable
            ],
       do:
         {409, Atom.to_string(reason), "The telephone operation conflicts with the current state"}

  defp error(:telephony_control_limit),
    do: {429, "telephony_control_limit", "Too many telephone control requests. Try again later"}

  defp error(reason)
       when reason in [
              :telephony_control_unsupported,
              :telephony_control_unavailable,
              :telephony_voicemail_unavailable,
              :voicemail_storage_unavailable,
              :voicemail_provider_unavailable,
              :voicemail_protection_unavailable,
              :voicemail_source_deletion_pending
            ],
       do:
         {503, Atom.to_string(reason), "A required telephone service is temporarily unavailable"}

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

  defp error(:invalid_whiteboard_operation),
    do: {422, "invalid_whiteboard_operation", "The whiteboard update is invalid"}

  defp error(:whiteboard_capacity_exceeded),
    do:
      {409, "whiteboard_capacity_exceeded",
       "This whiteboard reached its capacity. Clear the board to start a new scene."}

  defp error(:call_authorization_expired),
    do: {403, "call_authorization_expired", "Call access is no longer authorized"}

  defp error(:guest_account_conversion_not_enabled),
    do:
      {403, "guest_account_conversion_not_enabled",
       "Account creation is not permitted for this guest link"}

  defp error(:guest_account_conversion_forbidden),
    do:
      {403, "guest_account_conversion_forbidden",
       "Account creation is not permitted for this guest link"}

  defp error(:guest_account_conversion_email_mismatch),
    do:
      {403, "guest_account_conversion_email_mismatch",
       "Account creation is not permitted for the supplied email"}

  defp error(:guest_account_conversion_verification_failed),
    do:
      {403, "guest_account_conversion_verification_failed",
       "Account conversion verification failed"}

  defp error(:instant_rooms_unavailable),
    do: {503, "instant_rooms_unavailable", "Instant communication rooms are unavailable"}

  defp error(reason)
       when reason in [
              :ephemeral_replay_encryption_unavailable,
              :idempotency_replay_unavailable
            ],
       do: {503, "instant_rooms_unavailable", "Instant communication rooms are unavailable"}

  defp error(:idempotency_conflict),
    do:
      {409, "idempotency_conflict",
       "The idempotency key was already used with a different request"}

  defp error(:idempotency_replay_expired),
    do: {409, "idempotency_replay_expired", "The idempotency replay window has expired"}

  defp error(:invalid_guest_conversion_email),
    do: {422, "invalid_guest_conversion_email", "The account conversion email is invalid"}

  defp error(:guest_account_conversion_requires_single_use),
    do:
      {422, "guest_account_conversion_requires_single_use",
       "Account-enabled guest links must allow exactly one use"}

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
              :attachment_claimed,
              :audio_call_ended,
              :audio_call_ending,
              :audio_call_expired,
              :call_media_kind_conflict,
              :direct_conversation_unavailable,
              :guest_link_already_revoked,
              :guest_account_already_converted,
              :active_call_conflict,
              :busy,
              :call_ended,
              :invalid_call_action,
              :answer_required,
              :answered_elsewhere,
              :event_conflict
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
              :invalid_upload_expiry,
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
              :invalid_message_metadata,
              :invalid_whiteboard_reference,
              :too_many_whiteboard_elements,
              :invalid_message_link,
              :too_many_message_links,
              :invalid_reply_target,
              :invalid_mentions,
              :invalid_mention_id,
              :too_many_mentions,
              :invalid_message_body,
              :invalid_message_ids,
              :idempotency_key_required,
              :invalid_idempotency_key,
              :invalid_sequence,
              :invalid_search_query,
              :search_query_required,
              :invalid_file_scope,
              :invalid_file_category,
              :invalid_call_scope,
              :invalid_conversation_id,
              :unsupported_content_type,
              :invalid_attachment_size,
              :invalid_attachment_checksum,
              :attachment_checksum_mismatch,
              :invalid_attachments,
              :invalid_role,
              :invalid_status,
              :invalid_datetime,
              :invalid_cursor,
              :invalid_notification_filter,
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
              :invalid_call_signal,
              :audio_identity_invalid,
              :invalid_guest_scope,
              :invalid_guest_expiry,
              :invalid_guest_identity,
              :invalid_guest_account,
              :invalid_guest_display_name,
              :invalid_guest_link_expiry,
              :invalid_guest_link_max_uses,
              :invalid_guest_device,
              :invalid_ephemeral_room_title,
              :guest_links_not_supported,
              :invalid_destination
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
