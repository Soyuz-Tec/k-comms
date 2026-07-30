defmodule CommsCore.Notifications.Policy do
  @moduledoc false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.AccessGrant

  @spec authorize_delivery_management(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_delivery_management(subject),
    do:
      authorize_tenant_role(
        subject,
        :manage_notification_delivery,
        [:owner, :admin],
        true
      )

  @spec authorize_tenant_scope(map()) :: :ok | {:error, :forbidden}
  def authorize_tenant_scope(subject),
    do:
      authorize_tenant_role(
        subject,
        :read_tenant_notifications,
        [:owner, :admin],
        false
      )

  def authorize_scope(scope, subject) when scope in ["tenant", :tenant],
    do: authorize_tenant_scope(subject)

  def authorize_scope(_scope, _subject), do: :ok

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
