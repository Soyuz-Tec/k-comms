defmodule CommsCore.Accounts.MfaFactorState do
  @moduledoc false

  import Ecto.Query
  alias CommsCore.Accounts.MfaFactor
  alias CommsCore.Repo

  # Low-level authentication and session readers need only persisted factor
  # state, without depending on the enrollment/sign-in orchestration that uses
  # those same readers. Authority locks remain with each owning workflow.
  def enabled?(user_id, tenant_id) do
    Repo.exists?(
      from(f in MfaFactor,
        where: f.user_id == ^user_id and f.tenant_id == ^tenant_id and not is_nil(f.enabled_at)
      )
    )
  end
end
