defmodule CommsCore.Governance.VoicemailProtection do
  @moduledoc "Governance implementation of the Telephony-owned protection port."
  @behaviour CommsCore.Telephony.VoicemailProtectionPort
  import Ecto.Query
  alias CommsCore.{Repo, Telephony.VoicemailProtection}
  alias CommsCore.Governance.{DeletionRequest, LegalHold, RetentionPolicy, TenantLock}
  @impl true
  @spec protection(binary(), [binary()]) :: {:ok, VoicemailProtection.t()} | {:error, atom()}
  def protection(tenant_id, user_ids) when is_binary(tenant_id) and is_list(user_ids) do
    if Repo.in_transaction?() do
      TenantLock.lock!(tenant_id)

      held =
        Repo.exists?(
          from(h in LegalHold,
            where:
              h.tenant_id == ^tenant_id and h.status == :active and
                (h.scope_type == :tenant or h.subject_user_id in ^user_ids)
          )
        )

      days =
        Repo.one(
          from(p in RetentionPolicy,
            where: p.tenant_id == ^tenant_id and p.scope_type == :tenant and p.status == :active,
            select: p.retention_days
          )
        )

      blocked =
        Repo.exists?(
          from(r in DeletionRequest,
            where:
              r.tenant_id == ^tenant_id and r.status in [:approved, :in_progress] and
                r.target_type == :user and r.subject_user_id in ^user_ids
          )
        )

      {:ok, %VoicemailProtection{held: held, retention_days: days || 1, capture_blocked: blocked}}
    else
      {:error, :transaction_required}
    end
  end

  def protection(_, _), do: {:error, :invalid_voicemail_protection_request}
end
