defmodule CommsCore.AudioCalls.ProviderCall do
  @moduledoc """
  Ecto-free provider-room identity supplied to transactional media cleanup callbacks.
  """

  @enforce_keys [:id, :provider_room, :media_kind, :status]
  defstruct [:id, :provider_room, :media_kind, :status]

  @type t :: %__MODULE__{
          id: String.t(),
          provider_room: String.t(),
          media_kind: :audio | :video,
          status: :active | :ending | :ended
        }
end
