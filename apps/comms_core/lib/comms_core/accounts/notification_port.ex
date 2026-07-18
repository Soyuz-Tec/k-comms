defmodule CommsCore.Accounts.NotificationPort do
  @moduledoc """
  IdentityAccess-owned port for transaction-scoped notification effects.

  The configured adapter is composed at the application boundary. Commands
  must be executed inside the IdentityAccess transaction that owns the
  lifecycle change so a delivery failure rolls back the complete operation.
  """

  alias CommsCore.Accounts.{NotificationCommand, NotificationReceipt}
  alias CommsCore.Repo

  @type result :: :ok | {:ok, NotificationReceipt.t()} | {:error, term()}

  @callback execute(NotificationCommand.t()) :: result()

  @spec execute(NotificationCommand.t()) :: result()
  def execute(%NotificationCommand{} = command) do
    if Repo.in_transaction?() do
      dispatch(command)
    else
      {:error, :transaction_required}
    end
  end

  defp dispatch(command) do
    with {:ok, adapter} <-
           Application.fetch_env(:comms_core, :identity_notification_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :execute, 1) do
      adapter.execute(command)
    else
      _ -> {:error, :notification_delivery_unavailable}
    end
  end
end
