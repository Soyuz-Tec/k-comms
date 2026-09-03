defmodule CommsCore.PasswordRecovery do
  @moduledoc """
  Public password-recovery facade.

  IdentityAccess owns recovery persistence and notification/audit orchestration.
  Calls contributes access revocation through the transaction-required,
  IdentityAccess-owned lifecycle port.
  """

  alias CommsCore.Accounts.PasswordRecovery, as: IdentityPasswordRecovery
  alias CommsCore.Accounts.PasswordRecoveryResult

  @typedoc "Scalar values allowed across this facade boundary."
  @type public_scalar ::
          atom()
          | binary()
          | boolean()
          | integer()
          | float()
          | DateTime.t()
          | NaiveDateTime.t()
          | nil

  @typedoc "Persistence-neutral structured data with scalar leaves."
  @type public_map :: %{
          optional(atom() | binary()) =>
            public_scalar() | public_map() | [public_scalar() | public_map()]
        }

  @typedoc "Named DTOs owned by this bounded context."
  @type public_contract :: CommsCore.ValidationError.t()

  @type public_value :: public_scalar() | public_map() | public_contract()
  @type public_input ::
          public_value() | [public_value()] | function() | module()
  @type public_error ::
          atom()
          | CommsCore.ValidationError.t()
          | public_map()
          | {atom(), public_scalar() | public_map()}
  @type public_response ::
          public_value()
          | [public_value()]
          | {:ok, public_value() | [public_value()]}
          | {:error, public_error()}

  @spec materialize_notification(public_input()) :: public_response()
  @spec request(public_map()) :: public_response()
  @spec reset_command(public_map()) :: public_response()

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
