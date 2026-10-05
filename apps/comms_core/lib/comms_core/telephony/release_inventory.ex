defmodule CommsCore.Telephony.ReleaseInventory do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Telephony.{AgentState, Call, IvrEventReceipt, IvrMenu, IvrRun}

  def tenant_fingerprint_fragment(repo, tenant_id)
      when is_atom(repo) and is_binary(tenant_id) do
    %{
      telephony_calls: identities(repo, Call, tenant_id),
      telephony_ivr_menus: identities(repo, IvrMenu, tenant_id),
      telephony_ivr_runs: identities(repo, IvrRun, tenant_id),
      telephony_ivr_event_receipts: identities(repo, IvrEventReceipt, tenant_id),
      telephony_agent_states: identities(repo, AgentState, tenant_id)
    }
  end

  defp identities(repo, schema, tenant_id),
    do: repo.all(from(row in schema, where: row.tenant_id == ^tenant_id, select: row.id))
end
