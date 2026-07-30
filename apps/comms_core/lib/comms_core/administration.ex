defmodule CommsCore.Administration do
  @moduledoc """
  Stable public facade for tenant administration.

  Lifecycle, policy-query, settings-command, and audit-query responsibilities
  remain internal to this bounded context so callers do not depend on Ecto
  schemas or transaction details.
  """

  alias CommsCore.Administration.{
    AuditQueries,
    AuthorizationPolicy,
    CallPolicy,
    ConversationContentPolicy,
    Invitations,
    PolicyQueries,
    RetentionDefaults,
    SettingsCommands,
    TenantLifecycle,
    TenantView
  }

  def create_invitation(attrs, subject), do: Invitations.create(attrs, subject)
  def list_invitations(subject, status \\ nil), do: Invitations.list(subject, status)
  def revoke_invitation(id, attrs, subject), do: Invitations.revoke(id, attrs, subject)
  def accept_invitation(attrs), do: Invitations.accept(attrs)

  @spec authorize_read_capabilities(map()) :: :ok | {:error, :forbidden}
  def authorize_read_capabilities(subject) when is_map(subject),
    do: AuthorizationPolicy.authorize(:read_capabilities, subject)

  @spec authorize_administer_tenant(map()) :: :ok | {:error, :forbidden}
  def authorize_administer_tenant(subject) when is_map(subject),
    do: AuthorizationPolicy.authorize(:administer_tenant, subject)

  @spec authorize_manage_invitations(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_invitations(subject) when is_map(subject),
    do: AuthorizationPolicy.authorize(:manage_invitations, subject)

  @spec authorize_manage_settings(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_settings(subject) when is_map(subject),
    do: AuthorizationPolicy.authorize(:manage_tenant_settings, subject)

  @spec authorize_audit_tenant(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_audit_tenant(subject) when is_map(subject),
    do: AuthorizationPolicy.authorize(:audit_tenant, subject)

  defdelegate append_bootstrap_tenant(multi, operation, attrs), to: TenantLifecycle
  defdelegate create_bootstrap_tenant(attrs), to: TenantLifecycle
  defdelegate get_bootstrap_tenant_by_slug(slug), to: TenantLifecycle
  defdelegate any_tenant?(), to: TenantLifecycle
  defdelegate release_tenant_fingerprint_id(repo, tenant_slug), to: TenantLifecycle
  defdelegate delete_release_qualification_tenant(expected), to: TenantLifecycle

  @spec active_tenant(Ecto.UUID.t()) ::
          {:ok, TenantView.t()} | {:error, :tenant_unavailable}
  defdelegate active_tenant(tenant_id), to: TenantLifecycle

  @spec active_tenant_by_slug(String.t()) ::
          {:ok, TenantView.t()} | {:error, :tenant_unavailable}
  defdelegate active_tenant_by_slug(slug), to: TenantLifecycle

  @spec call_policy(Ecto.UUID.t()) :: {:ok, CallPolicy.t()} | {:error, :forbidden}
  defdelegate call_policy(tenant_id), to: PolicyQueries

  @spec lock_call_policy(Ecto.UUID.t()) ::
          {:ok, CallPolicy.t()} | {:error, :forbidden | :transaction_required}
  defdelegate lock_call_policy(tenant_id), to: PolicyQueries

  @spec retention_defaults(Ecto.UUID.t()) ::
          {:ok, RetentionDefaults.t()} | {:error, :invalid_tenant_id}
  defdelegate retention_defaults(tenant_id), to: PolicyQueries

  @spec conversation_content_policy(map()) ::
          {:ok, ConversationContentPolicy.t()} | {:error, :forbidden}
  defdelegate conversation_content_policy(subject), to: PolicyQueries
  defdelegate member_capabilities(subject), to: PolicyQueries

  defdelegate get_tenant_settings_view(subject), to: SettingsCommands, as: :get_view

  defdelegate update_tenant_settings_view(attrs, subject),
    to: SettingsCommands,
    as: :update_view

  defdelegate get_tenant_settings(subject), to: SettingsCommands, as: :get_settings

  defdelegate update_tenant_settings(attrs, subject),
    to: SettingsCommands,
    as: :update_settings

  defdelegate list_audit_events(params, subject), to: AuditQueries, as: :list
end
