defmodule CommsCore.Telephony.IvrProviderRequest do
  @moduledoc "Server-owned exact IVR identity and frozen PBX handles."
  @enforce_keys [:run_id, :call_id, :tenant_id, :provider_room, :provider_identity,
                 :step, :playback_id, :prompt_media, :bindings, :expires_at,
                 :effect_deadline_ms, :reconcile]
  defstruct [:run_id, :call_id, :tenant_id, :provider_room, :provider_identity,
             :step, :playback_id, :prompt_media, :bindings, :expires_at,
             :effect_deadline_ms, :reconcile, :destination, stage: :originate]
  @type t :: %__MODULE__{
          run_id: String.t(), call_id: String.t(), tenant_id: String.t(),
          provider_room: String.t(), provider_identity: String.t(), step: pos_integer(),
          playback_id: String.t(), prompt_media: String.t(), bindings: map(),
          expires_at: DateTime.t(), effect_deadline_ms: integer(), reconcile: boolean(),
          destination: String.t() | nil, stage: :originate | :connect
        }
end
