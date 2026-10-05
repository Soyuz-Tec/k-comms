defmodule CommsCore.AudioCalls.CalendarSync.ProviderAdapter do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.ProviderCapability

  def fetch do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :calendar_provider_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <-
           Enum.all?(
             [status: 1, authorization_url: 4, token: 1, event: 1, revoke: 3],
             fn {name, arity} -> function_exported?(adapter, name, arity) end
           ) do
      {:ok, adapter}
    else
      _ -> {:error, :calendar_provider_not_configured}
    end
  end

  def status(provider) do
    with {:ok, adapter} <- fetch(),
         %ProviderCapability{provider: ^provider, configured?: configured, qualified?: qualified} =
           capability <- adapter.status(provider),
         true <- is_boolean(configured) and is_boolean(qualified) do
      capability
    else
      _ ->
        %ProviderCapability{
          provider: provider,
          configured?: false,
          safe_reason: :calendar_provider_not_configured
        }
    end
  end
end
