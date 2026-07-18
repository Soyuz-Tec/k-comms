defmodule CommsWeb.IntegrationPresenter do
  alias CommsCore.Attachments.{AttachmentView, ScanAttemptView}
  alias CommsCore.Integrations.{WebhookDeliveryView, WebhookEndpointView}
  alias CommsCore.Notifications.{AttemptView, IntentView, PreferenceView}

  def notification_preference(%PreferenceView{} = preference) do
    %{
      email_enabled: preference.email_enabled,
      push_enabled: preference.push_enabled,
      in_app_enabled: preference.in_app_enabled,
      muted_event_types: preference.muted_event_types || [],
      updated_at: preference.updated_at
    }
  end

  def notification_intent(%IntentView{} = intent) do
    %{
      id: intent.id,
      event_type: intent.event_type,
      channel: intent.channel,
      destination_hint: intent.destination_hint,
      payload: intent.payload,
      status: intent.status,
      attempt_count: intent.attempt_count,
      delivered_at: intent.delivered_at,
      last_error_code: intent.last_error_code,
      inserted_at: intent.inserted_at,
      updated_at: intent.updated_at
    }
  end

  def notification_attempt(%AttemptView{} = attempt) do
    %{
      id: attempt.id,
      intent_id: attempt.intent_id,
      attempt_number: attempt.attempt_number,
      provider: attempt.provider,
      status: attempt.status,
      http_status: attempt.http_status,
      error_code: attempt.error_code,
      provider_message_id: attempt.provider_message_id,
      started_at: attempt.started_at,
      completed_at: attempt.completed_at
    }
  end

  def webhook_endpoint(%WebhookEndpointView{} = endpoint) do
    %{
      id: endpoint.id,
      name: endpoint.name,
      url: endpoint.url,
      status: endpoint.status,
      secret_version: endpoint.secret_version,
      event_types: endpoint.event_types,
      disabled_at: endpoint.disabled_at,
      inserted_at: endpoint.inserted_at,
      updated_at: endpoint.updated_at
    }
  end

  def webhook_delivery(%WebhookDeliveryView{} = delivery) do
    %{
      id: delivery.id,
      endpoint_id: delivery.endpoint_id,
      event_type: delivery.event_type,
      status: delivery.status,
      attempt_count: delivery.attempt_count,
      next_attempt_at: delivery.next_attempt_at,
      last_attempt_at: delivery.last_attempt_at,
      delivered_at: delivery.delivered_at,
      response_status: delivery.response_status,
      last_error_code: delivery.last_error_code,
      inserted_at: delivery.inserted_at,
      updated_at: delivery.updated_at
    }
  end

  def attachment_safety(%AttachmentView{} = attachment) do
    %{
      id: attachment.id,
      owner_user_id: attachment.owner_user_id,
      message_id: attachment.message_id,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      status: attachment.status,
      scan_status: attachment.scan_status,
      scan_verdict: attachment.scan_verdict,
      scan_provider: attachment.scan_provider,
      scan_attempts: attachment.scan_attempts,
      scan_error_code: attachment.scan_error_code,
      scanned_at: attachment.scanned_at,
      quarantined_at: attachment.quarantined_at,
      attempts: scan_attempts(attachment.scan_attempt_records),
      inserted_at: attachment.inserted_at,
      updated_at: attachment.updated_at
    }
  end

  defp scan_attempts(attempts) when is_list(attempts), do: Enum.map(attempts, &scan_attempt/1)
  defp scan_attempts(_), do: []

  defp scan_attempt(%ScanAttemptView{} = attempt) do
    %{
      id: attempt.id,
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
