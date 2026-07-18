defmodule CommsCore.Administration.CallLifecycleCommand do
  @moduledoc """
  Persistence-neutral TenantAdministration command for call-policy revocation.
  """

  @enforce_keys [:operation, :tenant_id, :media_kind, :reason]
  defstruct [:operation, :tenant_id, :media_kind, :reason]

  @type t :: %__MODULE__{
          operation: :tenant_media_disabled,
          tenant_id: binary(),
          media_kind: :audio | :video,
          reason: binary()
        }

  @spec tenant_media_disabled(binary(), :audio | :video, binary()) :: t()
  def tenant_media_disabled(tenant_id, media_kind, reason) do
    %__MODULE__{
      operation: :tenant_media_disabled,
      tenant_id: tenant_id,
      media_kind: media_kind,
      reason: reason
    }
  end
end
