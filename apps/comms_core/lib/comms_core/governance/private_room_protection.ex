defmodule CommsCore.Governance.PrivateRoomProtection do
  @behaviour CommsCore.Conversations.PrivateRoomProtectionPort
  import Ecto.Query
  alias CommsCore.Repo
  alias CommsCore.Governance.{TenantLock, LegalHold, DeletionRequest}
  alias CommsCore.Conversations.PrivateRoomProtection
  @impl true
  @spec protection(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, CommsCore.Conversations.PrivateRoomProtection.t()} | {:error, atom()}
  def protection(tenant, room, users) do
    if Repo.in_transaction?() do
      TenantLock.lock!(tenant)

      held =
        Repo.exists?(
          from(h in LegalHold,
            where:
              h.tenant_id == ^tenant and h.status == :active and
                (h.scope_type == :tenant or h.conversation_id == ^room or
                   h.subject_user_id in ^users)
          )
        )

      blocked =
        Repo.exists?(
          from(r in DeletionRequest,
            where:
              r.tenant_id == ^tenant and r.status in [:approved, :in_progress] and
                ((r.target_type == :conversation and r.conversation_id == ^room) or
                   (r.target_type == :user and r.subject_user_id in ^users))
          )
        )

      {:ok, %PrivateRoomProtection{held: held, capture_blocked: blocked}}
    else
      {:error, :transaction_required}
    end
  end
end
