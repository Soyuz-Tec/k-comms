defmodule CommsCore.Notifications.AvailabilityNotifier do
  @moduledoc "Boundary for content-free notification availability signals."

  @callback notify(CommsCore.Notifications.Availability.t()) :: :ok
end
