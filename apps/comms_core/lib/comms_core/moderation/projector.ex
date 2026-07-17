defmodule CommsCore.Moderation.Projector do
  @moduledoc false
  alias CommsCore.Moderation.{ActionView, CaseView, ModerationAction, ModerationCase}

  def case_view(%ModerationCase{} = value) do
    struct!(CaseView, %{
      id: value.id,
      reporter_user_id: value.reporter_user_id,
      subject_user_id: value.subject_user_id,
      conversation_id: value.conversation_id,
      message_id: value.message_id,
      assigned_to_user_id: value.assigned_to_user_id,
      category: value.category,
      summary: value.summary,
      details: value.details,
      priority: value.priority,
      status: value.status,
      resolved_at: value.resolved_at,
      version: value.lock_version,
      inserted_at: value.inserted_at,
      updated_at: value.updated_at
    })
  end

  def action(%ModerationAction{} = value) do
    struct!(ActionView, %{
      id: value.id,
      moderation_case_id: value.moderation_case_id,
      actor_user_id: value.actor_user_id,
      action_type: value.action_type,
      note: value.note,
      metadata: value.metadata,
      inserted_at: value.inserted_at
    })
  end
end
