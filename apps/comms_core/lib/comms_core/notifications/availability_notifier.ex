defmodule CommsCore.Notifications.AvailabilityNotifier do
  @moduledoc "Boundary for content-free notification availability signals."

  @callback notify(struct()) :: :ok
end

defmodule CommsCore.Notifications.AvailabilityNotifier.Noop do
  @behaviour CommsCore.Notifications.AvailabilityNotifier

  @impl true
  def notify(_intent), do: :ok
end
