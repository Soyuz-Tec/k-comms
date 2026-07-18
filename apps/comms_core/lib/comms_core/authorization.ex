defmodule CommsCore.Authorization do
  alias CommsCore.Authorization.Policy

  def authorize(action, subject, resource) do
    adapter =
      Application.get_env(:comms_core, :authorization_adapter, CommsCore.Authorization.DenyAll)

    Policy.authorize(adapter, action, subject, resource)
  end
end
