defmodule CommsCore.Telephony.VerifiedProviderEvent do
  @moduledoc "Provider data authenticated by the configured telephone webhook port."
  @enforce_keys [:event, :adapter]
  defstruct [:event, :adapter]
  @type t :: %__MODULE__{event: map(), adapter: module()}
end
