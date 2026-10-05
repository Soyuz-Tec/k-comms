defmodule CommsCore.Notifications.NativeCallTarget do
  @moduledoc "Persistence-neutral, content-free call owner target for recipient discovery."
  @enforce_keys [:owner, :call_id, :tenant_id]
  defstruct @enforce_keys ++ [:conversation_id]

  @type t :: %__MODULE__{
          owner: binary(),
          call_id: binary(),
          tenant_id: binary(),
          conversation_id: binary() | nil
        }
end
