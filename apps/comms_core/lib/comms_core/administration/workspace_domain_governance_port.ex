defmodule CommsCore.Administration.WorkspaceDomainGovernancePort do
  @moduledoc "Transaction-required governance fence before identity and domain locks."
  alias CommsCore.Administration.{DomainGovernanceFenceQuery, DomainGovernanceFenceReceipt}
  alias CommsCore.Repo

  @callback lock_workspace_domain_fence(DomainGovernanceFenceQuery.t()) ::
              {:ok, DomainGovernanceFenceReceipt.t()} | {:error, atom()}

  @spec lock_workspace_domain_fence(DomainGovernanceFenceQuery.t()) ::
          {:ok, DomainGovernanceFenceReceipt.t()} | {:error, atom()}
  def lock_workspace_domain_fence(%DomainGovernanceFenceQuery{} = query) do
    if Repo.in_transaction?() do
      with {:ok, _tenant_id} <- Ecto.UUID.cast(query.tenant_id),
           true <- is_integer(query.deadline),
           true <- System.monotonic_time(:millisecond) < query.deadline,
           true <- query.deadline - System.monotonic_time(:millisecond) <= 15_000,
           {:ok, adapter} <-
             Application.fetch_env(:comms_core, :workspace_domain_governance_adapter),
           true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
           true <- function_exported?(adapter, :lock_workspace_domain_fence, 1),
           {:ok, %DomainGovernanceFenceReceipt{tenant_id: tenant_id} = receipt} <-
             adapter.lock_workspace_domain_fence(query),
           true <- tenant_id == query.tenant_id do
        {:ok, receipt}
      else
        _ -> {:error, :domain_governance_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock_workspace_domain_fence(_query), do: {:error, :domain_governance_unavailable}
end
