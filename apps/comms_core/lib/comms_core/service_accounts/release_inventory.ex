defmodule CommsCore.ServiceAccounts.ReleaseInventory do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.ServiceAccounts.ServiceAccount

  @spec scim_credential_hazard_count(module()) :: non_neg_integer()
  def scim_credential_hazard_count(repo) when is_atom(repo) do
    # Expiry/revocation does not remove the persisted scope or its compatibility
    # requirement, including the database constraint restored by a down migration.
    repo.aggregate(
      from(account in ServiceAccount,
        where: "scim:read" in account.scopes or "scim:write" in account.scopes
      ),
      :count
    )
  end
end
