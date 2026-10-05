defmodule CommsCore.Telephony.VoicemailRequest do
  @moduledoc "Exact server-owned PBX recording handle. Never exposes provider credentials."
  @enforce_keys [:id, :tenant_id, :call_id, :recording_name, :operation]
  defstruct [
    :id,
    :tenant_id,
    :call_id,
    :recording_name,
    :operation,
    :provider_room,
    :provider_identity,
    :external_channel_id,
    :object
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          call_id: String.t(),
          recording_name: String.t(),
          operation: :reconcile | :delete | :delete_source,
          object: CommsCore.Telephony.VoicemailObject.t() | nil
        }
end
