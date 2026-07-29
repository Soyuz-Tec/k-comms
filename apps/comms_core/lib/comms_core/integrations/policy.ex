defmodule CommsCore.Integrations.Policy do
  @moduledoc false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.AccessGrant

  @spec authorize_read(map()) :: :ok | {:error, :forbidden}
  def authorize_read(subject),
    do: authorize_tenant_role(subject, :read_integrations, [:owner, :admin], false)

  @spec authorize_manage(map()) :: :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage(subject),
    do: authorize_tenant_role(subject, :manage_integrations, [:owner, :admin], true)

  defp authorize_tenant_role(subject, action, roles, require_step_up?) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{} = grant} ->
        cond do
          grant.role not in roles ->
            Accounts.audit_authorization_denial(action, subject, :forbidden)

          require_step_up? and not grant.step_up_recent? ->
            Accounts.audit_authorization_denial(action, subject, :step_up_required)

          true ->
            :ok
        end

      {:error, _reason} ->
        Accounts.audit_authorization_denial(action, subject, :forbidden)
    end
  end
end
