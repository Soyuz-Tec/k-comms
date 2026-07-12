defmodule CommsWeb.Auth.DenyAll do
  @behaviour CommsWeb.Auth
  @impl true
  def authenticate(_params, _connect_info), do: {:error, :unauthenticated}
end
