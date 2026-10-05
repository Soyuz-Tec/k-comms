defmodule CommsCore.Administration.CalendarPolicy do
  @moduledoc "Content-free tenant-owned calendar export policy."
  @enforce_keys [:tenant_id, :tenant_active?, :export_allowed?, :version]
  defstruct [:tenant_id, :tenant_active?, :export_allowed?, :version]

  @type t :: %__MODULE__{
          tenant_id: binary(),
          tenant_active?: boolean(),
          export_allowed?: boolean(),
          version: pos_integer()
        }
end
