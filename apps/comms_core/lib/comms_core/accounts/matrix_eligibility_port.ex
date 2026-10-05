defmodule CommsCore.Accounts.MatrixEligibilityPort do
  @moduledoc "IdentityAccess-owned transaction-scoped local participant withdrawal port."
  alias CommsCore.Accounts.{MatrixEligibilityCommand, MatrixEligibilityReceipt}

  @callback withdraw_user(MatrixEligibilityCommand.t()) ::
              {:ok, MatrixEligibilityReceipt.t()} | {:error, atom()}
  @spec withdraw_user(MatrixEligibilityCommand.t()) ::
          {:ok, MatrixEligibilityReceipt.t()} | {:error, atom()}
  def withdraw_user(%MatrixEligibilityCommand{} = command) do
    if CommsCore.Repo.in_transaction?() do
      with true <-
             match?({:ok, _}, Ecto.UUID.cast(command.tenant_id)) and
               match?({:ok, _}, Ecto.UUID.cast(command.user_id)) and
               match?(%DateTime{}, command.timestamp),
           {:ok, adapter} <- Application.fetch_env(:comms_core, :matrix_eligibility_adapter),
           {:ok, %MatrixEligibilityReceipt{fenced_rooms: count} = receipt} <-
             adapter.withdraw_user(command),
           true <- is_integer(count) and count >= 0,
           do: {:ok, receipt},
           else: (_ -> {:error, :matrix_eligibility_withdrawal_failed})
    else
      {:error, :transaction_required}
    end
  end
end
