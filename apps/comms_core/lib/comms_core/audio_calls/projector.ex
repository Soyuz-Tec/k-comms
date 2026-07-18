defmodule CommsCore.AudioCalls.Projector do
  @moduledoc false

  alias CommsCore.AudioCalls.{
    AudioCall,
    AudioCallParticipant,
    CallView,
    CredentialRequest,
    EvictionClaim,
    EvictionProgress,
    ProviderCall
  }

  def call(%AudioCall{} = call, can_end) when is_boolean(can_end) do
    struct!(CallView, %{
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
      version: call.lock_version,
      can_end: can_end
    })
  end

  def provider_call(%AudioCall{} = call) do
    struct!(ProviderCall, %{
      id: call.id,
      provider_room: call.provider_room,
      media_kind: call.media_kind,
      status: call.status
    })
  end

  def credential_request(%AudioCall{} = call, %AudioCallParticipant{} = participant) do
    struct!(CredentialRequest, %{
      call_id: call.id,
      participant_id: participant.id,
      provider_room: call.provider_room,
      media_kind: call.media_kind,
      provider_identity: participant.provider_identity
    })
  end

  def eviction_claim(%AudioCallParticipant{} = participant, %AudioCall{} = call) do
    struct!(EvictionClaim, %{
      participant_id: participant.id,
      provider_call: provider_call(call),
      provider_identity: participant.provider_identity,
      enforce_until: participant.eviction_enforce_until
    })
  end

  def eviction_progress(%AudioCallParticipant{} = participant) do
    struct!(EvictionProgress, %{
      participant_id: participant.id,
      eviction_status: participant.eviction_status
    })
  end
end
