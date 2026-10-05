defmodule CommsCore.Governance.ArtifactProtection do
  @moduledoc "Governance adapter for the Calls-owned artifact protection port."
  @behaviour CommsCore.AudioCalls.ArtifactProtectionPort
  import Ecto.Query
  alias CommsCore.AudioCalls.ArtifactProtection
  alias CommsCore.Governance.{DeletionRequest, LegalHold, RetentionPolicy, TenantLock}
  alias CommsCore.Repo

  @impl true
  @spec protection(binary(), binary(), [binary()]) ::
          {:ok, ArtifactProtection.t()} | {:error, atom()}
  def protection(tenant_id, conversation_id, user_ids)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_list(user_ids) do
    if Repo.in_transaction?() do
      # Serializes artifact purge with the existing legal-hold creation lock.
      TenantLock.lock!(tenant_id)

      held =
        Repo.exists?(
          from(h in LegalHold,
            where:
              h.tenant_id == ^tenant_id and h.status == :active and
                (h.scope_type == :tenant or h.conversation_id == ^conversation_id or
                   h.subject_user_id in ^user_ids)
          )
        )

      policy =
        Repo.one(
          from(p in RetentionPolicy,
            where:
              p.tenant_id == ^tenant_id and p.status == :active and
                (p.scope_type == :tenant or p.conversation_id == ^conversation_id),
            order_by: [desc_nulls_last: p.conversation_id],
            limit: 1
          )
        )

      {:ok,
       %ArtifactProtection{
         held: held,
         capture_blocked:
           Repo.exists?(
             from(r in DeletionRequest,
               where:
                 r.tenant_id == ^tenant_id and r.status in [:approved, :in_progress] and
                   ((r.target_type == :conversation and r.conversation_id == ^conversation_id) or
                      (r.target_type == :user and r.subject_user_id in ^user_ids))
             )
           ),
         retention_days: if(policy, do: policy.retention_days, else: 30)
       }}
    else
      {:error, :transaction_required}
    end
  end

  def protection(_, _, _), do: {:error, :invalid_artifact_protection_request}
end
