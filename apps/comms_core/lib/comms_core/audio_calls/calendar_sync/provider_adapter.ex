defmodule CommsCore.AudioCalls.CalendarSync.ProviderAdapter do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.ProviderCapability
  alias CommsCore.Repo
  @behaviour CommsCore.AudioCalls.CalendarSync.ProviderPort

  @impl true
  @spec authorization_url(:google | :microsoft, binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def authorization_url(provider, state, nonce, verifier) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- fetch(),
           do: adapter.authorization_url(provider, state, nonce, verifier)
    else
      {:error, :transaction_required}
    end
  end

  @impl true
  @spec token(CommsCore.AudioCalls.CalendarSync.OAuthRequest.t()) ::
          {:ok, CommsCore.AudioCalls.CalendarSync.TokenReceipt.t()} | {:error, atom()}
  def token(%CommsCore.AudioCalls.CalendarSync.OAuthRequest{} = request) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- fetch(), do: adapter.token(request)
    else
      {:error, :transaction_required}
    end
  end

  @impl true
  @spec event(CommsCore.AudioCalls.CalendarSync.EventCommand.t()) ::
          {:ok, CommsCore.AudioCalls.CalendarSync.EventReceipt.t()} | {:error, atom()}
  def event(%CommsCore.AudioCalls.CalendarSync.EventCommand{} = command) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- fetch(), do: adapter.event(command)
    else
      {:error, :transaction_required}
    end
  end

  @impl true
  @spec revoke(:google | :microsoft, binary(), integer()) ::
          {:ok, :confirmed | :external_unconfirmed} | {:error, atom()}
  def revoke(provider, refresh_token, deadline) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- fetch(), do: adapter.revoke(provider, refresh_token, deadline)
    else
      {:error, :transaction_required}
    end
  end

  defp fetch do
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

  @impl true
  @spec status(:google | :microsoft) :: ProviderCapability.t() | {:error, :transaction_required}
  def status(provider) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- fetch(),
           %ProviderCapability{
             provider: ^provider,
             configured?: configured,
             qualified?: qualified
           } =
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
    else
      {:error, :transaction_required}
    end
  end
end
