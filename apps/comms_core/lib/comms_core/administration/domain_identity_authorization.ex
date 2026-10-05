defmodule CommsCore.Administration.DomainIdentityAuthorization do
  @moduledoc "Transaction-scoped authority requested by the workspace domain owner."
  @enforce_keys [:subject, :deadline]
  defstruct [:subject, :deadline]
  @type t :: %__MODULE__{subject: map(), deadline: integer()}
end
