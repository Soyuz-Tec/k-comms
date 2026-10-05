defmodule CommsCore.Notifications.NativeCallRequest do
  @moduledoc "Exact call owner identifiers plus retained native registration authority."
  @enforce_keys [:owner, :call_id, :tenant_id, :user_id, :device_id, :session_id]
  defstruct @enforce_keys ++ [:conversation_id, :deadline]

  @type t :: %__MODULE__{
          owner: binary(),
          call_id: binary(),
          tenant_id: binary(),
          user_id: binary(),
          device_id: binary(),
          session_id: binary(),
          conversation_id: binary() | nil,
          deadline: integer()
        }
end
