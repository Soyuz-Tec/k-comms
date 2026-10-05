defmodule CommsCore.AudioCalls.CalendarSync.ProviderPort do
  @moduledoc "Fixed-provider delegated calendar protocol owned by AudioCalls."
  alias CommsCore.AudioCalls.CalendarSync.{
    EventCommand,
    EventReceipt,
    OAuthRequest,
    ProviderCapability,
    TokenReceipt
  }

  @callback status(:google | :microsoft) ::
              ProviderCapability.t() | {:error, :transaction_required}

  @callback authorization_url(:google | :microsoft, binary(), binary(), binary()) ::
              {:ok, binary()} | {:error, atom()}
  @callback token(OAuthRequest.t()) :: {:ok, TokenReceipt.t()} | {:error, atom()}
  @callback event(EventCommand.t()) :: {:ok, EventReceipt.t()} | {:error, atom()}
  @callback revoke(:google | :microsoft, binary(), integer()) ::
              {:ok, :confirmed | :external_unconfirmed} | {:error, atom()}
end
