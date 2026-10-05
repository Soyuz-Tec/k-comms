defmodule CommsCore.Telephony.IvrEvent do
  @moduledoc "Verified caller-only PBX event; no user or session is inferred from a digit."
  @enforce_keys [:event_id, :body_fingerprint, :type, :run_id,
                 :step, :channel_id, :occurred_at]
  defstruct [:event_id, :body_fingerprint, :type, :tenant_id, :call_id, :run_id,
             :step, :channel_id, :provider_room, :provider_identity, :occurred_at,
             :digit, :playback_id, :media_uri]
  @type t :: %__MODULE__{
          event_id: String.t(), body_fingerprint: String.t(), type: :digit | :playback_finished,
          tenant_id: String.t(), call_id: String.t(), run_id: String.t(), step: pos_integer(),
          channel_id: String.t(), provider_room: String.t(), provider_identity: String.t(),
          occurred_at: DateTime.t(), digit: String.t() | nil,
          playback_id: String.t() | nil, media_uri: String.t() | nil
        }
end
