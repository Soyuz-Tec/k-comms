defmodule CommsCore.AudioCalls.CredentialRequest do
  @moduledoc """
  Ecto-free provider credential request supplied while Calls still holds its row locks.
  """

  @enforce_keys [:call_id, :participant_id, :provider_room, :media_kind, :provider_identity]
  defstruct [:call_id, :participant_id, :provider_room, :media_kind, :provider_identity]

  @type t :: %__MODULE__{
          call_id: String.t(),
          participant_id: String.t(),
          provider_room: String.t(),
          media_kind: :audio | :video,
          provider_identity: String.t()
        }
end
