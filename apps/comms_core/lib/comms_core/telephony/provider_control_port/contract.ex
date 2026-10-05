defmodule CommsCore.Telephony.ProviderControlPort.Contract do
  @moduledoc "Provider truth for supported controls and route target qualification."
  @callback capabilities() :: map()
  @callback authorize_destination(String.t()) :: :ok | {:error, atom()}
  @callback verify_event(binary(), binary()) :: {:ok, map()} | {:error, atom()}
  @callback cleanup_call(CommsCore.Telephony.ProviderCommand.t()) :: :ok | {:error, atom()}
  @callback bound_call_status(CommsCore.Telephony.ProviderCommand.t()) ::
              {:ok, :active | :ended} | {:error, atom()}
  @callback execute_control(CommsCore.Telephony.ControlRequest.t()) ::
              {:ok, :submitted | map()} | {:error, atom()}
end
