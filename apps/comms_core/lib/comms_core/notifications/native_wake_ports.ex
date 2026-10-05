defmodule CommsCore.Notifications.NativeWakePorts do
  @moduledoc false
  alias CommsCore.Notifications.{NativeCallWakePort, NativePushProviderPort}
  def authorize(request), do: NativeCallWakePort.authorize(request)
  def recipients(target), do: NativeCallWakePort.recipients(target)
  def admit(request, subject, issuer), do: NativeCallWakePort.admit(request, subject, issuer)
  def deliver(delivery, deadline), do: NativePushProviderPort.deliver(delivery, deadline)
  def status(), do: NativePushProviderPort.status()
end
