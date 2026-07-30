defmodule CommsCore.Governance.Authorization do
  @moduledoc false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.AccessGrant

  def authorize(subject) when is_map(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{} = grant} ->
        cond do
          grant.role not in [:owner, :compliance_admin] ->
            Accounts.audit_authorization_denial(:govern_tenant, subject, :forbidden)

          not grant.step_up_recent? ->
            Accounts.audit_authorization_denial(
              :govern_tenant,
              subject,
              :step_up_required
            )

          true ->
            :ok
        end

      {:error, _reason} ->
        Accounts.audit_authorization_denial(:govern_tenant, subject, :forbidden)
    end
  end

  def authorize(_subject), do: {:error, :forbidden}
end
