defmodule CommsCore.AudioCalls.ReleaseInventory do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}
  alias CommsCore.AudioCalls.Artifacts.{Artifact, Consent, Segment, Summary}

  def tenant_fingerprint_fragment(repo, tenant_id)
      when is_atom(repo) and is_binary(tenant_id) do
    %{
      call_artifacts:
        repo.all(from(a in Artifact, where: a.tenant_id == ^tenant_id, select: a.id)),
      call_artifact_consents:
        repo.all(from(c in Consent, where: c.tenant_id == ^tenant_id, select: c.id)),
      call_artifact_segments:
        repo.all(from(s in Segment, where: s.tenant_id == ^tenant_id, select: s.id)),
      call_artifact_summaries:
        repo.all(from(s in Summary, where: s.tenant_id == ^tenant_id, select: s.id)),
      calls:
        repo.all(
          from(call in AudioCall,
            where: call.tenant_id == ^tenant_id,
            select: call.id
          )
        ),
      call_participants:
        repo.all(
          from(participant in AudioCallParticipant,
            where: participant.tenant_id == ^tenant_id,
            select: participant.id
          )
        )
    }
  end
end
