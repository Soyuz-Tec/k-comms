defmodule CommsCore.SharedDocuments.ProtectionPort do
  @moduledoc "Exact transaction-only governed document protection contract."
  alias CommsCore.{Repo, SharedDocuments.Protection}

  @callback protection(binary(), binary() | nil, [binary()]) ::
              {:ok, Protection.t()} | {:error, atom()}
  @spec protection(binary(), binary() | nil, [binary()]) ::
          {:ok, Protection.t()} | {:error, atom()}
  def protection(tenant_id, conversation_id, user_ids) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <-
             Application.fetch_env(:comms_core, :shared_document_protection_adapter),
           true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
           true <- function_exported?(adapter, :protection, 3),
           {:ok, %Protection{held: held, capture_blocked: blocked} = result} <-
             adapter.protection(tenant_id, conversation_id, user_ids),
           true <- is_boolean(held) and is_boolean(blocked) do
        {:ok, result}
      else
        {:error, _} = error -> error
        _ -> {:error, :document_protection_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end
end
