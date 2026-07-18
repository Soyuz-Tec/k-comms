defmodule CommsCore.Notifications.AvailabilityNotifier.Noop do
  @behaviour CommsCore.Notifications.AvailabilityNotifier.Contract

  @impl true
  def notify(_intent), do: :ok
end
