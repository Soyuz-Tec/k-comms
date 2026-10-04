defmodule CommsCore.Telephony.ProviderCommand do
  @moduledoc "Persistence-free exact provider room and telephone leg command."
  @enforce_keys [
    :call_id,
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
    :provider_room,
    :provider_identity,
    :direction,
    :status,
    :from_number,
    :to_number,
    :inbound_trunk_id,
    :outbound_trunk_id,
    reconcile: false
  ]

  @type t :: %__MODULE__{
          call_id: String.t(),
          provider_room: String.t(),
          provider_identity: String.t(),
          direction: :inbound | :outbound,
          status: atom(),
          from_number: String.t(),
          to_number: String.t(),
          inbound_trunk_id: String.t(),
          outbound_trunk_id: String.t(),
          reconcile: boolean()
        }
end
