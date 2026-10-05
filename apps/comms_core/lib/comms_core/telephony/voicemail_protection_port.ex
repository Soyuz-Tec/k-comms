defmodule CommsCore.Telephony.VoicemailProtectionPort do
  @moduledoc "Telephony-owned legal-hold and retention projection; fails closed."
  alias CommsCore.{Repo, Telephony.VoicemailProtection}
  @callback protection(binary(), [binary()]) :: {:ok, VoicemailProtection.t()} | {:error, atom()}
  @spec protection(binary(), [binary()]) :: {:ok, VoicemailProtection.t()} | {:error, atom()}
  def protection(tenant_id, user_ids) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- Application.fetch_env(:comms_core, :voicemail_protection_adapter),
           true <-
             is_atom(adapter) and Code.ensure_loaded?(adapter) and
               function_exported?(adapter, :protection, 2),
           {:ok, %VoicemailProtection{held: held, retention_days: days} = projection} <-
             adapter.protection(tenant_id, user_ids),
           true <-
             is_boolean(held) and is_boolean(projection.capture_blocked) and is_integer(days) and
               days in 1..36_500 do
        {:ok, projection}
      else
        {:error, _} = error -> error
        _ -> {:error, :voicemail_protection_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end
end
