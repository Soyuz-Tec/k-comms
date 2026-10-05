defmodule CommsCore.Telephony.ProvisioningRequest do
  @moduledoc "Server-only, short-lived authority for one exact provider inspection/effect."
  @derive {Inspect, except: [:lease_token, :phone_number]}
  @enforce_keys [
    :command_id,
    :tenant_id,
    :lease_token,
    :lease_expires_at,
    :version,
    :mode,
    :phone_number,
    :inbound_trunk_id,
    :outbound_trunk_id
  ]
  defstruct [
    :command_id,
    :tenant_id,
    :lease_token,
    :lease_expires_at,
    :version,
    :mode,
    :phone_number,
    :inbound_trunk_id,
    :outbound_trunk_id,
    :dispatch_rule_id,
    effect_consumed: false
  ]

  @type t :: %__MODULE__{}
end
