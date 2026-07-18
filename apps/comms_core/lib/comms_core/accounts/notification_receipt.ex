defmodule CommsCore.Accounts.NotificationReceipt do
  @moduledoc """
  Persistence-neutral receipt for an IdentityAccess notification command.
  """

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: binary()}
end
