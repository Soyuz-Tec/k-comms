defmodule CommsCore.Accounts.AuthenticationResult do
  @moduledoc "Stable result returned after bootstrap, sign-in, or token refresh."
  @derive {Inspect, except: [:refresh_token]}
  defstruct [:session_id, :refresh_token, :tenant, :user, :device, :conversation]

  @type t :: %__MODULE__{
          session_id: Ecto.UUID.t(),
          refresh_token: String.t(),
          tenant: CommsCore.Administration.TenantView.t(),
          user: CommsCore.Accounts.UserView.t(),
          device: CommsCore.Accounts.DeviceView.t(),
          conversation: struct() | nil
        }
end
