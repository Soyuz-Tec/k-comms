defmodule CommsCore.Telephony.ProviderWebhookPort do
  @moduledoc "Resolves the configured provider verifier without a Core integration dependency."
  alias CommsCore.Telephony.VerifiedProviderEvent

  @spec verify_webhook(binary(), binary()) :: {:ok, VerifiedProviderEvent.t()} | {:error, atom()}
  def verify_webhook(body, authorization) do
    with {:ok, adapter} <- adapter(),
         {:ok, event} when is_map(event) <- adapter.verify_webhook(body, authorization) do
      {:ok, %VerifiedProviderEvent{event: event, adapter: adapter}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_webhook}
    end
  end

  @spec authorized_adapter?(module()) :: boolean()
  def authorized_adapter?(caller) do
    with {:ok, adapter} <- adapter(), true <- caller == adapter do
      adapter.authorized_adapter?(caller) == true
    else
      _ -> false
    end
  end

  defp adapter do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :telephony_callback_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :verify_webhook, 2),
         true <- function_exported?(adapter, :authorized_adapter?, 1) do
      {:ok, adapter}
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end
end
