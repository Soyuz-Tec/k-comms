defmodule CommsCore.Governance.FederationProtection do
  @moduledoc "Governance FIRST contribution, before quota/identity/conversation/provider locks."
  @behaviour CommsCore.Conversations.Federation.ProtectionPort
  import Ecto.Query
  alias CommsCore.Conversations.Federation.Protection
  alias CommsCore.Governance.{DeletionRequest, LegalHold, TenantLock}
  alias CommsCore.Repo
  @impl true
  @spec protection(binary(), binary() | nil, [binary()]) ::
          {:ok, Protection.t()} | {:error, atom()}
  def protection(tenant_id, conversation_id, user_ids)
      when is_list(user_ids) and length(user_ids) <= 101 do
    if Repo.in_transaction?() do
      TenantLock.lock!(tenant_id)
      conversations = if is_binary(conversation_id), do: [conversation_id], else: []

      held =
        Repo.exists?(
          from(h in LegalHold,
            where:
              h.tenant_id == ^tenant_id and h.status == :active and
                (h.scope_type == :tenant or h.conversation_id in ^conversations or
                   h.subject_user_id in ^user_ids)
          )
        )

      capture_blocked =
        Repo.exists?(
          from(d in DeletionRequest,
            where:
              d.tenant_id == ^tenant_id and d.status in [:approved, :in_progress] and
                ((d.target_type == :conversation and d.conversation_id in ^conversations) or
                   (d.target_type == :user and d.subject_user_id in ^user_ids))
          )
        )

      {:ok, %Protection{held: held, capture_blocked: capture_blocked}}
    else
      {:error, :transaction_required}
    end
  end

  def protection(_, _, _), do: {:error, :invalid_federation_scope}
end
