defmodule CommsCore.Administration.WorkspaceDomainIdentityPort do
  @moduledoc """
  TenantAdministration-owned retained identity authority for domain disclosure.

  The IdentityAccess provider fences the exact tenant, user, device and session
  on the caller transaction. A DNS proof never supplies identity authority.
  """
  alias CommsCore.Administration.{DomainIdentityAuthorization, IdentityGrant}
  alias CommsCore.Repo

  @callback authorize_workspace_domain(DomainIdentityAuthorization.t()) ::
              {:ok, IdentityGrant.t()} | {:error, atom()}

  @spec authorize_workspace_domain(DomainIdentityAuthorization.t()) ::
          {:ok, IdentityGrant.t()} | {:error, atom()}
  def authorize_workspace_domain(%DomainIdentityAuthorization{} = command) do
    if Repo.in_transaction?() do
      with true <- is_map(command.subject) and is_integer(command.deadline),
           true <- System.monotonic_time(:millisecond) < command.deadline,
           true <- command.deadline - System.monotonic_time(:millisecond) <= 15_000,
           {:ok, adapter} <-
             Application.fetch_env(:comms_core, :workspace_domain_identity_adapter),
           true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
           true <- function_exported?(adapter, :authorize_workspace_domain, 1),
           {:ok, %IdentityGrant{} = grant} <- adapter.authorize_workspace_domain(command),
           true <- grant.tenant_id == value(command.subject, :tenant_id),
           true <- grant.user_id == value(command.subject, :user_id),
           true <- grant.role in [:owner, :admin] and grant.step_up_recent? == true do
        {:ok, grant}
      else
        {:error, reason} when reason in [:forbidden, :step_up_required] -> {:error, reason}
        _ -> {:error, :domain_identity_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end

  def authorize_workspace_domain(_command), do: {:error, :forbidden}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
