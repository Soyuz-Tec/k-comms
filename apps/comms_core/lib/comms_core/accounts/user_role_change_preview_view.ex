defmodule CommsCore.Accounts.UserRoleChangePreviewView do
  @moduledoc "Advisory impact snapshot; the governed mutation must revalidate every condition."
  alias CommsCore.Accounts.{AccessGrant, RoleCapabilityView}

  @enforce_keys [
    :target_id,
    :current_role,
    :requested_role,
    :current_version,
    :target_status,
    :target_access_scope,
    :role_policy_allows,
    :blockers,
    :added,
    :removed
  ]
  defstruct [
    :target_id,
    :current_role,
    :requested_role,
    :current_version,
    :target_status,
    :target_access_scope,
    :role_policy_allows,
    :blockers,
    :added,
    :removed,
    advisory: true,
    scope: :tenant,
    governance_review_required: true
  ]

  @type t :: %__MODULE__{
          target_id: Ecto.UUID.t(),
          current_role: AccessGrant.tenant_role(),
          requested_role: AccessGrant.tenant_role(),
          current_version: pos_integer(),
          target_status: :active | :suspended,
          target_access_scope: :workspace | :conversation_only,
          role_policy_allows: boolean(),
          blockers: [:forbidden | :last_owner_required],
          added: [RoleCapabilityView.t()],
          removed: [RoleCapabilityView.t()],
          advisory: true,
          scope: :tenant,
          governance_review_required: true
        }
end
