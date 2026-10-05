defmodule CommsCore.Notifications.NativePushProviderPort.Contract do
  alias CommsCore.Notifications.NativeDelivery
  @callback deliver(NativeDelivery.t(), integer()) :: :ok | {:error, :invalid_token | :uncertain | :unavailable | :rejected}
  @callback status() :: map()
end
