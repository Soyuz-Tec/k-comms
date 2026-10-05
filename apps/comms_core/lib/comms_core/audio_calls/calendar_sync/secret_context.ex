defmodule CommsCore.AudioCalls.CalendarSync.SecretContext do
  @moduledoc "Purpose and complete ownership binding for calendar AEAD material."
  @enforce_keys [:tenant_id, :user_id, :provider, :resource_id, :generation, :purpose]
  defstruct [:tenant_id, :user_id, :provider, :resource_id, :generation, :purpose]

  @type t :: %__MODULE__{
          tenant_id: binary(),
          user_id: binary(),
          provider: :google | :microsoft,
          resource_id: binary(),
          generation: pos_integer(),
          purpose: :challenge | :credential | :external_identity | :event_identity
        }
end
