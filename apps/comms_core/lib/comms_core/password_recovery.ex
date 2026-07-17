defmodule CommsCore.PasswordRecovery do
  @moduledoc """
  Public password-recovery facade.

  IdentityAccess owns recovery persistence and notification/audit orchestration.
  Calls contributes access revocation to the existing reset transaction through
  the callback supplied here.
  """

  alias CommsCore.Accounts.PasswordRecovery, as: IdentityPasswordRecovery
  alias CommsCore.Accounts.PasswordRecoveryResult
  alias CommsCore.AudioCalls

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
  def reset(attrs) do
    IdentityPasswordRecovery.reset(attrs, &AudioCalls.revoke_for_user/3)
  end

  def reset_command(attrs) do
    reset(attrs)
  end
end
