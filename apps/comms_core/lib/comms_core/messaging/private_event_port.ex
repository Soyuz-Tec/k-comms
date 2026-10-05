defmodule CommsCore.Messaging.PrivateEventPort do
  alias CommsCore.Messaging.{PrivateEventCommand, PrivateEventReceipt}

  @spec send_encrypted(PrivateEventCommand.t()) ::
          {:ok, PrivateEventReceipt.t()} | {:error, atom()}
  def send_encrypted(%PrivateEventCommand{} = command) do
    with true <- Application.get_env(:comms_core, :private_rooms_enabled, false),
         {:ok, adapter} <- Application.fetch_env(:comms_core, :private_event_adapter),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :send_encrypted, 1) do
      adapter.send_encrypted(command)
    else
      _ -> {:error, :private_event_provider_unavailable}
    end
  end
end
