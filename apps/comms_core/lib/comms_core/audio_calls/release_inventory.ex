defmodule CommsCore.AudioCalls.ReleaseInventory do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}

  def tenant_fingerprint_fragment(repo, tenant_id)
      when is_atom(repo) and is_binary(tenant_id) do
    %{
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
