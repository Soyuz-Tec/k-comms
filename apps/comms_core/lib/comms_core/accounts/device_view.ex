defmodule CommsCore.Accounts.DeviceView do
  @moduledoc "Stable device projection for adapter-facing reads."
  defstruct [:id, :user_id, :name, :platform, :last_seen_at, :revoked_at]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          name: String.t(),
          platform: String.t(),
          last_seen_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil
        }
end
