defmodule CommsCore.Accounts.AuthenticationResult do
  @moduledoc "Stable result returned after bootstrap, sign-in, or token refresh."
  @derive {Inspect, except: [:refresh_token]}
  defstruct [:session_id, :refresh_token, :tenant, :user, :device, :conversation]
end
