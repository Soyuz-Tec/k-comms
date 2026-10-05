defmodule CommsCore.Governance.MatrixAccessProtection do
  @behaviour CommsCore.Accounts.MatrixAccessProtectionPort
  import Ecto.Query
  alias CommsCore.Repo
  alias CommsCore.Governance.{TenantLock, DeletionRequest}
  @impl true
  @spec protection(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, CommsCore.Accounts.MatrixAccessProtection.t()} | {:error, atom()}
  def protection(tenant, user) do
    if Repo.in_transaction?() do
      TenantLock.lock!(tenant)

      blocked =
        Repo.exists?(
          from(r in DeletionRequest,
            where:
              r.tenant_id == ^tenant and r.target_type == :user and r.subject_user_id == ^user and
                r.status in [:approved, :in_progress]
          )
        )

      {:ok, %CommsCore.Accounts.MatrixAccessProtection{capture_blocked: blocked}}
    else
      {:error, :transaction_required}
    end
  end
end
