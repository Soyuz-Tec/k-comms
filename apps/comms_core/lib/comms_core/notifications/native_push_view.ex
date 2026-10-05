defmodule CommsCore.Notifications.NativePushView do
  @moduledoc "Safe registration receipt. Transport material and hashes never cross this read contract."
  @enforce_keys [
    :id,
    :device_id,
    :version,
    :platform,
    :channel,
    :application_id,
    :environment,
    :status,
    :expires_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: binary(),
          device_id: binary(),
          version: pos_integer(),
          platform: binary(),
          channel: binary(),
          application_id: binary(),
          environment: binary(),
          status: binary(),
          expires_at: DateTime.t()
        }
end
