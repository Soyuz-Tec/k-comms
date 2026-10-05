defmodule CommsCore.Administration.DiscoveryView do
  @moduledoc "Public opt-in sign-in hint without user or enrollment authority."
  @enforce_keys [:available]
  defstruct [:available, :sign_in_path]
  @type t :: %__MODULE__{available: boolean(), sign_in_path: String.t() | nil}
end
