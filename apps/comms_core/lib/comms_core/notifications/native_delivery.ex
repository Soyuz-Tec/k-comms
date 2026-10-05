defmodule CommsCore.Notifications.NativeDelivery do
  @moduledoc "Transient encrypted-token materialization for one bounded provider dispatch. Never persist this value."
  @derive {Inspect, except: [:token]}
  @enforce_keys [:wake_id, :registration_id, :registration_version, :platform, :channel, :application_id, :environment, :token, :expires_at]
  defstruct @enforce_keys
  @type t :: %__MODULE__{wake_id: binary(), registration_id: binary(), registration_version: pos_integer(),
                         platform: binary(), channel: binary(), application_id: binary(), environment: binary(),
                         token: binary(), expires_at: DateTime.t()}
end
