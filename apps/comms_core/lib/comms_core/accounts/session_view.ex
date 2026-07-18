defmodule CommsCore.Accounts.SessionView do
  @moduledoc "Stable session projection without refresh-token persistence fields."
  defstruct [
    :id,
    :user_id,
    :device_id,
    :expires_at,
    :last_used_at,
    :revoked_at,
    :inserted_at,
    :step_up_at,
    :platform_role,
    :platform_role_expires_at
  ]
end
