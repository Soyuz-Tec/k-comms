defmodule CommsCore.Administration.TenantView do
  @moduledoc "Stable tenant projection owned by TenantAdministration."
  defstruct [:id, :name, :slug, :status]
end
