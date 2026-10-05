defmodule CommsCore.Administration.DomainUserErasureReceipt do
  @moduledoc "Counts of removed personal challenges and detached tenant proof leases."
  @enforce_keys [:removed_challenges, :detached_verified_leases]
  defstruct [:removed_challenges, :detached_verified_leases]

  @type t :: %__MODULE__{
          removed_challenges: non_neg_integer(),
          detached_verified_leases: non_neg_integer()
        }
end
