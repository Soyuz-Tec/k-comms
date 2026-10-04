defmodule CommsCore.Telephony.CredentialRequest do
  @moduledoc "Verified, room-scoped identity for telephone media credential issuance."
  @enforce_keys [
    :call_id,
    :provider_room,
    :provider_identity,
    :user_id,
    :device_id,
    :session_id,
    :authorization_expires_at
  ]
  defstruct [
    :call_id,
    :provider_room,
    :provider_identity,
    :user_id,
    :device_id,
    :session_id,
    :authorization_expires_at
  ]

  @type t :: %__MODULE__{
          call_id: String.t(),
          provider_room: String.t(),
          provider_identity: String.t(),
          user_id: String.t(),
          device_id: String.t(),
          session_id: String.t(),
          authorization_expires_at: DateTime.t()
        }
end
