defmodule CommsCore.Governance.TenantLock do
  @moduledoc false

  alias CommsCore.Repo

  def lock!(tenant_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [tenant_id]
    )

    :ok
  end
end
