defmodule CommsCore.Accounts.WorkspaceDomainAuthority do
  @moduledoc false
  alias CommsCore.Accounts.{AccessGrant, ContentWriteGrant}
  alias CommsCore.Administration.{DomainIdentityAuthorization, IdentityGrant}

  @spec authorize(DomainIdentityAuthorization.t()) ::
          {:ok, IdentityGrant.t()} | {:error, atom()}
  def authorize(%DomainIdentityAuthorization{subject: subject, deadline: deadline}) do
    with {:ok, %AccessGrant{} = grant} <- ContentWriteGrant.lock(subject, deadline),
         true <- grant.account_type == :human and grant.access_scope == :workspace,
         true <- grant.role in [:owner, :admin],
         :ok <- recent_proof(grant) do
      {:ok,
       %IdentityGrant{
         tenant_id: grant.tenant_id,
         user_id: grant.user_id,
         role: grant.role,
         step_up_recent?: true
       }}
    else
      false -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recent_proof(%AccessGrant{step_up_recent?: true}), do: :ok
  defp recent_proof(_grant), do: {:error, :step_up_required}
end
