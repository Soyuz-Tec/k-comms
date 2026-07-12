defmodule CommsWeb.Auth do
  @callback authenticate(map(), map()) :: {:ok, map()} | {:error, term()}
  def authenticate(params, connect_info) do
    adapter = Application.get_env(:comms_web, :auth_adapter, CommsWeb.Auth.DenyAll)
    adapter.authenticate(params, connect_info)
  end
end
