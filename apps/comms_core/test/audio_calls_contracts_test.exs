defmodule CommsCore.AudioCalls.ContractsTest do
  use ExUnit.Case, async: true

  alias CommsCore.AudioCalls.{
    AudioCall,
    AudioCallParticipant,
    CallView,
    CredentialRequest,
    EvictionClaim,
    EvictionProgress,
    Projector,
    ProviderCall
  }

  test "projects adapter and provider contracts without Ecto metadata" do
    timestamp = ~U[2026-07-17 12:00:00.000000Z]

    call = %AudioCall{
      id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      started_by_user_id: Ecto.UUID.generate(),
      provider_room: "kc_call_exact_room",
      media_kind: :video,
      status: :active,
      started_at: timestamp,
      expires_at: DateTime.add(timestamp, 300, :second),
      lock_version: 3
    }

    participant = %AudioCallParticipant{
      id: Ecto.UUID.generate(),
      provider_identity: "kc_exact_participant_identity",
      eviction_status: :pending,
      eviction_enforce_until: DateTime.add(timestamp, 660, :second)
    }

    assert %CallView{version: 3, can_end: true} = call_view = Projector.call(call, true)
    assert %ProviderCall{id: call_id} = provider_call = Projector.provider_call(call)

    assert %CredentialRequest{
             call_id: ^call_id,
             participant_id: participant_id,
             provider_identity: "kc_exact_participant_identity"
           } = Projector.credential_request(call, participant)

    assert participant_id == participant.id
    assert provider_call.status == :active

    assert %EvictionClaim{provider_call: ^provider_call} =
             Projector.eviction_claim(participant, call)

    assert %EvictionProgress{eviction_status: :pending} =
             Projector.eviction_progress(participant)

    for contract <- [
          call_view,
          provider_call,
          Projector.credential_request(call, participant),
          Projector.eviction_claim(participant, call),
          Projector.eviction_progress(participant)
        ] do
      refute Map.has_key?(contract, :__meta__)
    end
  end
end
