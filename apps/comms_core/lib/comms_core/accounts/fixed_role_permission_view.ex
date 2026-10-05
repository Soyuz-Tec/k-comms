defmodule CommsCore.Accounts.FixedRolePermissionView do
  @moduledoc "Bounded existing tenant role; it grants no resource or platform access."
  alias CommsCore.Accounts.{AccessGrant, RoleCapabilityView}
  @enforce_keys [:role, :capabilities]
  defstruct [:role, :capabilities]
  @type t :: %__MODULE__{role: AccessGrant.tenant_role(), capabilities: [RoleCapabilityView.t()]}
end
