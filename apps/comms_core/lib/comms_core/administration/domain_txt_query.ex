defmodule CommsCore.Administration.DomainTXTQuery do
  @moduledoc "Bounded DNS-only lookup for one exact workspace domain challenge."
  @enforce_keys [:name, :timeout_ms]
  defstruct [:name, :timeout_ms]
  @type t :: %__MODULE__{name: String.t(), timeout_ms: 1..5000}
end
