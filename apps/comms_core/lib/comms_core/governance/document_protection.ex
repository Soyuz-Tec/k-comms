defmodule CommsCore.Governance.DocumentProtection do
  @moduledoc "Governance implements the exact Collaboration-owned document protection projection."
  @behaviour CommsCore.SharedDocuments.ProtectionPort
  import Ecto.Query
  alias CommsCore.Governance.{DeletionRequest, LegalHold, TenantLock}
  alias CommsCore.SharedDocuments.Protection
  alias CommsCore.Repo
  @impl true
  @spec protection(binary(), binary() | nil, [binary()]) ::
          {:ok, Protection.t()} | {:error, atom()}
  def protection(tenant_id, conversation_id, user_ids)
      when is_binary(tenant_id) and (is_binary(conversation_id) or is_nil(conversation_id)) and
             is_list(user_ids) do
    if Repo.in_transaction?() do
      TenantLock.lock!(tenant_id)
      conversation_ids = if conversation_id, do: [conversation_id], else: []

      {:ok,
       %Protection{
         held:
           Repo.exists?(
             from(hold in LegalHold,
               where:
                 hold.tenant_id == ^tenant_id and hold.status == :active and
                   (hold.scope_type == :tenant or hold.conversation_id in ^conversation_ids or
                      hold.subject_user_id in ^user_ids)
             )
           ),
         capture_blocked:
           Repo.exists?(
             from(request in DeletionRequest,
               where:
                 request.tenant_id == ^tenant_id and
                   request.status in [:approved, :in_progress] and
                   ((request.target_type == :conversation and
                       request.conversation_id in ^conversation_ids) or
                      (request.target_type == :user and request.subject_user_id in ^user_ids))
             )
           )
       }}
    else
      {:error, :transaction_required}
    end
  end

  def protection(_, _, _), do: {:error, :invalid_document_protection_request}
end
