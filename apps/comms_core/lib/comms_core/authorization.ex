defmodule CommsCore.Authorization do
  @callback authorize(atom(), map(), struct() | map()) :: :ok | {:error, term()}

  def authorize(action, subject, resource) do
    adapter = Application.get_env(:comms_core, :authorization_adapter, CommsCore.Authorization.DenyAll)
    adapter.authorize(action, subject, resource)
  end
end
