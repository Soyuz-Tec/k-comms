defmodule CommsCore.Notifications.NativeCallWakePort.Contract do
  alias CommsCore.Notifications.{NativeCallRequest, NativeCallTarget}
  @callback recipients(NativeCallTarget.t()) :: {:ok, [binary()]} | {:error, atom()}
  @callback authorize(NativeCallRequest.t()) :: {:ok, DateTime.t()} | {:error, atom()}
  @callback admit(NativeCallRequest.t(), map(), function()) :: {:ok, map()} | {:error, atom()}
end
