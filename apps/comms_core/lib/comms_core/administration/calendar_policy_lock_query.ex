defmodule CommsCore.Administration.CalendarPolicyLockQuery do
  @moduledoc "Tenant policy lock for offline export or restricted cleanup."
  @enforce_keys [:tenant_id, :purpose, :deadline_ms]
  defstruct [:tenant_id, :purpose, :deadline_ms]
  @type t :: %__MODULE__{tenant_id: binary(), purpose: :export | :cleanup, deadline_ms: integer()}
end
