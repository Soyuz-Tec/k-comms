defmodule CommsCore.Messaging.PrivateEventPort.Contract do
  alias CommsCore.Messaging.{PrivateEventCommand, PrivateEventReceipt}

  @callback send_encrypted(PrivateEventCommand.t()) ::
              {:ok, PrivateEventReceipt.t()} | {:error, atom()}
end
