defmodule CommsIntegrations.Calendar do
  @moduledoc "Fixed-host delegated Google Calendar and Microsoft Graph adapter."
  @behaviour CommsCore.AudioCalls.CalendarSync.ProviderPort
  alias CommsIntegrations.Calendar.{Events, OAuth}
  alias CommsCore.AudioCalls.CalendarSync.ProviderCapability
  @impl true
  def status(provider) when provider in [:google, :microsoft] do
    case CommsIntegrations.Calendar.Config.load(provider) do
      {:ok, _} ->
        %ProviderCapability{provider: provider, configured?: true}

      {:error, reason} ->
        %ProviderCapability{provider: provider, configured?: false, safe_reason: reason}
    end
  end

  @impl true
  defdelegate authorization_url(provider, state, nonce, verifier), to: OAuth
  @impl true
  defdelegate token(request), to: OAuth
  @impl true
  defdelegate event(command), to: Events
  @impl true
  defdelegate revoke(provider, token, deadline), to: OAuth
end
