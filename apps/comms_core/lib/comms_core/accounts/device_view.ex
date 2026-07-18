defmodule CommsCore.Accounts.DeviceView do
  @moduledoc "Stable device projection for adapter-facing reads."
  defstruct [:id, :user_id, :name, :platform, :last_seen_at, :revoked_at]
end
