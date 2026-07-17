defmodule CommsCore.Governance.Projector do
  @moduledoc false

  alias CommsCore.Governance.{
    DeletionRequest,
    DeletionRequestView,
    LegalHold,
    LegalHoldView,
    RetentionPolicy,
    RetentionPolicyView
  }

  def retention_policy(%RetentionPolicy{} = value) do
    struct!(RetentionPolicyView, %{
      id: value.id,
      conversation_id: value.conversation_id,
      name: value.name,
      scope_type: value.scope_type,
      retention_days: value.retention_days,
      delete_attachments: value.delete_attachments,
      status: value.status,
      version: value.lock_version,
      inserted_at: value.inserted_at,
      updated_at: value.updated_at
    })
  end

  def legal_hold(%LegalHold{} = value) do
    struct!(LegalHoldView, %{
      id: value.id,
      created_by_user_id: value.created_by_user_id,
      subject_user_id: value.subject_user_id,
      conversation_id: value.conversation_id,
      name: value.name,
      reason: value.reason,
      scope_type: value.scope_type,
      status: value.status,
      starts_at: value.starts_at,
      released_at: value.released_at,
      version: value.lock_version,
      inserted_at: value.inserted_at
    })
  end

  def deletion_request(%DeletionRequest{} = value) do
    struct!(DeletionRequestView, %{
      id: value.id,
      requested_by_user_id: value.requested_by_user_id,
      subject_user_id: value.subject_user_id,
      conversation_id: value.conversation_id,
      message_id: value.message_id,
      target_type: value.target_type,
      reason: value.reason,
      status: value.status,
      scheduled_for: value.scheduled_for,
      completed_at: value.completed_at,
      execution_started_at: value.execution_started_at,
      execution_attempts: value.execution_attempts,
      execution_error: value.execution_error,
      evidence: value.evidence,
      version: value.lock_version,
      inserted_at: value.inserted_at,
      updated_at: value.updated_at
    })
  end
end
