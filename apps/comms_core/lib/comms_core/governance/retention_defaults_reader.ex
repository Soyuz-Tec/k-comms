defmodule CommsCore.Governance.RetentionDefaultsReader do
  @moduledoc false

  alias CommsCore.Administration
  alias CommsCore.Administration.RetentionDefaults

  @spec fetch(Ecto.UUID.t()) ::
          {:ok, RetentionDefaults.t()} | {:error, :invalid_tenant_id}
  def fetch(tenant_id), do: Administration.retention_defaults(tenant_id)
end
