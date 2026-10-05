defmodule CommsCore.Accounts.MatrixAccessProtectionPort do
  alias CommsCore.{Repo, Accounts.MatrixAccessProtection}

  @callback protection(Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, MatrixAccessProtection.t()} | {:error, atom()}
  @spec protection(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MatrixAccessProtection.t()} | {:error, atom()}
  def protection(tenant, user) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- Application.fetch_env(:comms_core, :matrix_access_protection_adapter),
           true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :protection, 2),
           {:ok, %MatrixAccessProtection{capture_blocked: blocked} = result} <-
             adapter.protection(tenant, user),
           true <- is_boolean(blocked),
           do: {:ok, result}
    else
      {:error, :transaction_required}
    end
  end
end
