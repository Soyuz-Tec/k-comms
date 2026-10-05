defmodule CommsCore.AudioCalls.Artifacts.Metadata do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Repo
  alias CommsCore.AudioCalls.{ArtifactView, AudioCallParticipant, AuthorizationPolicy}
  alias CommsCore.AudioCalls.Artifacts.{Artifact, Consent}

  def view(a, subject, call, policy_version) do
    consents = Repo.all(from(c in Consent, where: c.artifact_id == ^a.id))
    participants = if call && call.status == :active, do: admitted(call), else: []

    current =
      if participants == [],
        do: consents,
        else:
          Enum.filter(consents, fn c -> Enum.any?(participants, &(&1.id == c.participant_id)) end)

    own = Enum.find(consents, &(&1.session_id == value(subject, :session_id)))

    can_manage =
      if not is_nil(call) and not guest?(subject),
        do:
          AuthorizationPolicy.authorize(
            if(call.media_kind == :video, do: :end_video_call, else: :end_audio_call),
            subject,
            call
          ) == :ok,
        else: false

    %ArtifactView{
      id: a.id,
      conversation_id: a.conversation_id,
      call_id: a.call_id,
      meeting_id: a.meeting_id,
      source_artifact_id: a.source_artifact_id,
      transcript_language: a.transcript_language,
      summary_requested: a.summary_requested,
      summary_policy_version: if(a.summary_requested, do: policy_version, else: nil),
      summary_consent_required_count:
        if(a.summary_requested, do: max(length(current), length(participants)), else: 0),
      summary_consent_accepted_count: Enum.count(current, & &1.summary_accepted),
      my_summary_consent: if(own, do: own.summary_accepted, else: nil),
      can_withdraw_summary_consent:
        a.kind == :recording and a.summary_requested and
          Enum.any?(consents, &(&1.user_id == value(subject, :user_id) and &1.summary_accepted)),
      summary_request_available:
        a.kind == :transcript and a.status == :available and a.summary_requested and
          not is_nil(call) and call.status == :ended and
          source_summary_consented?(a, policy_version) and
          not Repo.exists?(
            from(child in Artifact,
              where:
                child.tenant_id == ^a.tenant_id and
                  child.source_artifact_id == ^a.id and child.kind == :summary
            )
          ),
      recognition_mode: if(a.kind == :transcript, do: "post_recording", else: nil),
      recognition_model_sha256: a.recognition_model_sha256,
      kind: a.kind,
      status: a.status,
      created_at: a.inserted_at,
      started_at: a.started_at,
      ended_at: a.ended_at,
      expires_at: a.expires_at,
      failure_code: a.failure_code,
      consent_required_count: max(length(current), length(participants)),
      consent_accepted_count: Enum.count(current, & &1.accepted),
      my_consent:
        if(own,
          do: own.accepted,
          else:
            if(Enum.any?(participants, &(&1.session_id == value(subject, :session_id))),
              do: false,
              else: nil
            )
        ),
      can_manage: can_manage,
      byte_size: a.byte_size,
      content_type: a.content_type
    }
  end

  defp source_summary_consented?(transcript, policy_version) do
    source =
      Repo.get_by(Artifact,
        id: transcript.source_artifact_id,
        tenant_id: transcript.tenant_id,
        call_id: transcript.call_id,
        kind: :recording
      )

    if source && source.summary_requested && source.status == :available &&
         is_nil(source.erasure_requested_at) && DateTime.compare(source.expires_at, now()) == :gt do
      decisions =
        Repo.all(
          from(c in Consent,
            where: c.tenant_id == ^source.tenant_id and c.artifact_id == ^source.id
          )
        )

      decisions != [] and
        Enum.all?(
          decisions,
          &(&1.accepted and &1.summary_accepted and
              &1.summary_policy_version == policy_version)
        )
    else
      false
    end
  end

  defp admitted(call),
    do:
      Repo.all(
        from(p in AudioCallParticipant,
          where:
            p.tenant_id == ^call.tenant_id and p.audio_call_id == ^call.id and
              p.status == :admitted
        )
      )

  defp guest?(subject),
    do:
      value(subject, :account_type) in [:guest, "guest"] or
        is_binary(value(subject, :guest_conversation_id))

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
