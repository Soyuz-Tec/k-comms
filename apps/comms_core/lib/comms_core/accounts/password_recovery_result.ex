defmodule CommsCore.Accounts.PasswordRecoveryResult do
  @moduledoc "Stable result returned after a successful password reset."

  @enforce_keys [:revoked_session_ids]
  defstruct [:revoked_session_ids]

  @type t :: %__MODULE__{revoked_session_ids: [Ecto.UUID.t()]}
end
