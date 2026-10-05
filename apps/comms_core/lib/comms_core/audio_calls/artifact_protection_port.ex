defmodule CommsCore.AudioCalls.ArtifactProtectionPort do
  @moduledoc "Calls-owned transaction-scoped governance projection."
  alias CommsCore.AudioCalls.ArtifactProtection
  alias CommsCore.Repo

  @callback protection(binary(), binary(), [binary()]) ::
              {:ok, ArtifactProtection.t()} | {:error, atom()}
  @spec protection(binary(), binary(), [binary()]) ::
          {:ok, ArtifactProtection.t()} | {:error, atom()}
  def protection(tenant_id, conversation_id, user_ids) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- Application.fetch_env(:comms_core, :artifact_protection_adapter),
           true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
           true <- function_exported?(adapter, :protection, 3),
           {:ok,
            %ArtifactProtection{held: held, retention_days: days, capture_blocked: blocked} =
              protection} <-
             adapter.protection(tenant_id, conversation_id, user_ids),
           true <-
             is_boolean(held) and is_boolean(blocked) and is_integer(days) and days in 1..36_500 do
        {:ok, protection}
      else
        {:error, _} = error -> error
        _ -> {:error, :artifact_protection_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end
end
