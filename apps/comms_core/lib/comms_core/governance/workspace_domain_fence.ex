defmodule CommsCore.Governance.WorkspaceDomainFence do
  @moduledoc false
  alias CommsCore.Administration.DomainGovernanceFenceQuery
  alias CommsCore.Administration.DomainGovernanceFenceReceipt
  alias CommsCore.Governance.TenantLock
  alias CommsCore.Repo

  @spec lock(DomainGovernanceFenceQuery.t()) ::
          {:ok, DomainGovernanceFenceReceipt.t()} | {:error, atom()}
  def lock(%DomainGovernanceFenceQuery{tenant_id: tenant_id, deadline: deadline}) do
    if Repo.in_transaction?() and is_integer(deadline) do
      with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
           remaining when remaining in 1..15_000 <- deadline - System.monotonic_time(:millisecond) do
        timeout = Integer.to_string(remaining) <> "ms"

        Repo.query!(
          "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
          [timeout]
        )

        TenantLock.lock!(tenant_id)

        if System.monotonic_time(:millisecond) < deadline,
          do: {:ok, %DomainGovernanceFenceReceipt{tenant_id: tenant_id}},
          else: {:error, :domain_governance_unavailable}
      else
        _ -> {:error, :domain_governance_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end
end
