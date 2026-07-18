defmodule CommsCore.Administration.AdmissionPolicyReader do
  @moduledoc false

  alias CommsCore.Administration.{AdmissionPolicy, TenantSettings}
  alias CommsCore.Repo

  @spec read(Ecto.UUID.t()) :: AdmissionPolicy.t()
  def read(tenant_id) when is_binary(tenant_id) do
    settings =
      Repo.get_by(TenantSettings, tenant_id: tenant_id) ||
        %TenantSettings{tenant_id: tenant_id}

    %AdmissionPolicy{
      max_active_users: settings.max_active_users,
      max_active_conversations: settings.max_active_conversations,
      max_conversation_members: settings.max_conversation_members
    }
  end
end
