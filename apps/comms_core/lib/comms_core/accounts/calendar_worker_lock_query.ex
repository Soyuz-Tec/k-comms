defmodule CommsCore.Accounts.CalendarWorkerLockQuery do
  @moduledoc "Exact durable offline principal and export/delete-only purpose."
  @enforce_keys [:tenant_id, :user_id, :purpose, :deadline_ms]
  defstruct [:tenant_id, :user_id, :purpose, :deadline_ms]

  @type t :: %__MODULE__{
          tenant_id: binary(),
          user_id: binary(),
          purpose: :export | :cleanup,
          deadline_ms: integer()
        }
end
