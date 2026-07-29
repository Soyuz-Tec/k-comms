defmodule CommsWeb.Presenters.Calls do
  @moduledoc false

  alias CommsCore.AudioCalls.{CallSessionView, CallView}

  def audio_call(%CallView{} = call) do
    %{
      id: call.id,
      tenant_id: call.tenant_id,
      conversation_id: call.conversation_id,
      started_by_user_id: call.started_by_user_id,
      ended_by_user_id: call.ended_by_user_id,
      media_kind: call.media_kind,
      status: call.status,
      started_at: call.started_at,
      expires_at: call.expires_at,
      ended_at: call.ended_at,
      end_reason: call.end_reason,
      version: call.version,
      can_end: call.can_end
    }
  end

  def call_session(%CallSessionView{} = call) do
    %{
      id: call.id,
      conversation_id: call.conversation_id,
      started_by_user_id: call.started_by_user_id,
      ended_by_user_id: call.ended_by_user_id,
      media_kind: call.media_kind,
      status: call.status,
      started_at: call.started_at,
      expires_at: call.expires_at,
      ended_at: call.ended_at,
      end_reason: call.end_reason,
      duration_seconds: call.duration_seconds,
      can_end: call.can_end
    }
  end
end
