defmodule CommsCore.Administration.RetentionDefaults do
  @moduledoc """
  Stable tenant retention defaults exposed to policy-owning contexts.

  The projection deliberately contains only the tenant identifier and the
  optional default retention period. Tenant settings persistence remains
  internal to TenantAdministration.
  """

  @enforce_keys [:tenant_id, :default_retention_days]
  defstruct [:tenant_id, :default_retention_days]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          default_retention_days: pos_integer() | nil
        }
end
