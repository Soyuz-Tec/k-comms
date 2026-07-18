defmodule CommsCore.Administration.CallPolicy do
  @moduledoc """
  Ecto-free tenant capability projection consumed by Calls.

  Missing tenant-settings rows use the same enabled-by-default behavior as
  TenantAdministration.
  """

  @enforce_keys [:tenant_id, :allow_audio_calls, :allow_video_calls]
  defstruct [:tenant_id, :allow_audio_calls, :allow_video_calls]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          allow_audio_calls: boolean(),
          allow_video_calls: boolean()
        }
end
