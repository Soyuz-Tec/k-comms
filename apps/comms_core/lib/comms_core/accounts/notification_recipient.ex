defmodule CommsCore.Accounts.NotificationRecipient do
  @moduledoc """
  Minimal IdentityAccess projection used to address a notification.

  The email destination is deliberately excluded from inspected output.
  """

  @derive {Inspect, except: [:email]}
  @enforce_keys [:user_id, :email]
  defstruct [:user_id, :email]

  @type t :: %__MODULE__{
          user_id: String.t(),
          email: String.t()
        }
end
