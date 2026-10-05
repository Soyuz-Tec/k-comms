defmodule CommsCore.SharedDocuments.Protection do
  @moduledoc "Collaboration-owned legal hold and pending-erasure projection."
  @enforce_keys [:held, :capture_blocked]
  defstruct [:held, :capture_blocked]
  @type t :: %__MODULE__{held: boolean(), capture_blocked: boolean()}
end
