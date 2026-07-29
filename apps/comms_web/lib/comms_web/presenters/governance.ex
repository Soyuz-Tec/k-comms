defmodule CommsWeb.Presenters.Governance do
  @moduledoc false

  alias CommsCore.Governance.{DeletionRequestView, LegalHoldView, RetentionPolicyView}
  alias CommsCore.Moderation.{ActionView, CaseView}

  def moderation_case(%CaseView{} = moderation_case) do
    %{
      id: moderation_case.id,
      reporter_user_id: moderation_case.reporter_user_id,
      subject_user_id: moderation_case.subject_user_id,
      conversation_id: moderation_case.conversation_id,
      message_id: moderation_case.message_id,
      assigned_to_user_id: moderation_case.assigned_to_user_id,
      category: moderation_case.category,
      summary: moderation_case.summary,
      details: moderation_case.details,
      priority: moderation_case.priority,
      status: moderation_case.status,
      resolved_at: moderation_case.resolved_at,
      version: moderation_case.version,
      inserted_at: moderation_case.inserted_at,
      updated_at: moderation_case.updated_at
    }
  end

  def moderation_action(%ActionView{} = action) do
    %{
      id: action.id,
      moderation_case_id: action.moderation_case_id,
      actor_user_id: action.actor_user_id,
      action_type: action.action_type,
      note: action.note,
      metadata: action.metadata,
      inserted_at: action.inserted_at
    }
  end

  def retention_policy(%RetentionPolicyView{} = policy) do
    %{
      id: policy.id,
      conversation_id: policy.conversation_id,
      name: policy.name,
      scope_type: policy.scope_type,
      retention_days: policy.retention_days,
      delete_attachments: policy.delete_attachments,
      status: policy.status,
      version: policy.version,
      inserted_at: policy.inserted_at,
      updated_at: policy.updated_at
    }
  end

  def legal_hold(%LegalHoldView{} = hold) do
    %{
      id: hold.id,
      created_by_user_id: hold.created_by_user_id,
      subject_user_id: hold.subject_user_id,
      conversation_id: hold.conversation_id,
      name: hold.name,
      reason: hold.reason,
      scope_type: hold.scope_type,
      status: hold.status,
      starts_at: hold.starts_at,
      released_at: hold.released_at,
      version: hold.version,
      inserted_at: hold.inserted_at
    }
  end

  def deletion_request(%DeletionRequestView{} = request) do
    %{
      id: request.id,
      requested_by_user_id: request.requested_by_user_id,
      subject_user_id: request.subject_user_id,
      conversation_id: request.conversation_id,
      message_id: request.message_id,
      target_type: request.target_type,
      reason: request.reason,
      status: request.status,
      scheduled_for: request.scheduled_for,
      completed_at: request.completed_at,
      execution_started_at: request.execution_started_at,
      execution_attempts: request.execution_attempts,
      execution_error: request.execution_error,
      evidence: request.evidence,
      version: request.version,
      inserted_at: request.inserted_at,
      updated_at: request.updated_at
    }
  end
end
