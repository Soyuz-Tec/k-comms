defmodule CommsCore.PasswordRecovery do
  @moduledoc """
  Public password-recovery facade.

  IdentityAccess owns recovery persistence and notification/audit orchestration.
  Calls contributes access revocation through the transaction-required,
  IdentityAccess-owned lifecycle port.
  """

  alias CommsCore.Accounts.PasswordRecovery, as: IdentityPasswordRecovery
  alias CommsCore.Accounts.PasswordRecoveryResult

  defdelegate event_type(), to: IdentityPasswordRecovery
  defdelegate request(attrs), to: IdentityPasswordRecovery
  defdelegate materialize_notification(intent), to: IdentityPasswordRecovery

  @spec reset(map()) ::
          {:ok, PasswordRecoveryResult.t()}
          | {:error,
             :invalid_password_recovery_token
             | :password_recovery_unavailable
             | :weak_password
             | term()}
  def reset(attrs), do: IdentityPasswordRecovery.reset(attrs)

  def reset_command(attrs) do
    reset(attrs)
  end
end
