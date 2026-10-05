defmodule CommsCore.AudioCalls.CalendarSync.ProtectionPort do
  @moduledoc "Calendar-owned, transaction-scoped Governance adapter contract."
  alias CommsCore.AudioCalls.CalendarSync.{ProtectionQuery, ProtectionReceipt}
  alias CommsCore.Repo
  @callback protection(ProtectionQuery.t()) :: {:ok, ProtectionReceipt.t()} | {:error, atom()}

  def protection(%ProtectionQuery{} = query) do
    with true <- Repo.in_transaction?(),
         {:ok, adapter} <- Application.fetch_env(:comms_core, :calendar_protection_adapter),
         true <-
           is_atom(adapter) and Code.ensure_loaded?(adapter) and
             function_exported?(adapter, :protection, 1),
         {:ok, %ProtectionReceipt{held?: held, capture_blocked?: blocked} = receipt} <-
           adapter.protection(query),
         true <- is_boolean(held) and is_boolean(blocked) do
      {:ok, receipt}
    else
      _ -> {:error, :calendar_protection_unavailable}
    end
  end

  def protection(_), do: {:error, :calendar_protection_unavailable}
end
