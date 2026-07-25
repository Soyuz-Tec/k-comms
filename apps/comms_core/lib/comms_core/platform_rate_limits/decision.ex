defmodule CommsCore.PlatformRateLimits.Decision do
  @moduledoc """
  Ecto-free result of one cluster-wide public-mutation admission decision.
  """

  @enforce_keys [:allowed, :retry_after]
  defstruct [:allowed, :retry_after]

  @type t :: %__MODULE__{
          allowed: boolean(),
          retry_after: non_neg_integer()
        }
end
