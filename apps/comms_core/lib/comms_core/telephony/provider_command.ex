defmodule CommsCore.Telephony.ProviderCommand do
  @moduledoc "Persistence-free exact provider room and telephone leg command."
  @enforce_keys [
    :call_id,
    :tenant_id,
    :route_id,
    :provider_room,
    :provider_identity,
    :direction,
    :status,
    :from_number,
    :to_number,
    :inbound_trunk_id,
    :outbound_trunk_id
  ]
  defstruct [
    :call_id,
    :tenant_id,
    :route_id,
    :provider_room,
    :provider_identity,
    :direction,
    :status,
    :from_number,
    :to_number,
    :inbound_trunk_id,
    :outbound_trunk_id,
    pbx_state: %{},
    control_state: "connected",
    expires_at: nil,
    reconcile: false
  ]

  @type t :: %__MODULE__{
          call_id: String.t(),
          tenant_id: String.t(),
          route_id: String.t() | nil,
          provider_room: String.t(),
          provider_identity: String.t(),
          direction: :inbound | :outbound,
          status: atom(),
          from_number: String.t(),
          to_number: String.t(),
          inbound_trunk_id: String.t(),
          outbound_trunk_id: String.t(),
          pbx_state: map(),
          control_state: String.t(),
          expires_at: DateTime.t() | nil,
          reconcile: boolean()
        }
end
