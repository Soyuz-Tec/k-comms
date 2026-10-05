defmodule CommsCore.Administration.DomainGovernanceFenceReceipt do
  @moduledoc "A transaction-retained governance tenant fence without foreign data."
  @enforce_keys [:tenant_id]
  defstruct [:tenant_id]
  @type t :: %__MODULE__{tenant_id: Ecto.UUID.t()}
end
