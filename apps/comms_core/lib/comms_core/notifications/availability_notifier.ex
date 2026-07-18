defmodule CommsCore.Notifications.AvailabilityNotifier do
  @moduledoc """
  Technical boundary for content-free notification availability signals.

  The configured implementation receives only the stable `Availability`
  projection. Notification persistence and delivery details remain internal to
  NotificationDelivery. Implementations conform to
  `CommsCore.Notifications.AvailabilityNotifier.Contract`.
  """

  alias CommsCore.Notifications.Availability

  @default_implementation CommsCore.Notifications.AvailabilityNotifier.Noop

  @spec notify(Availability.t()) :: :ok | {:error, term()}
  def notify(%Availability{} = availability) do
    implementation = configured_implementation()
    implementation.notify(availability)
  end

  defp configured_implementation do
    Application.get_env(
      :comms_core,
      :notification_availability_notifier,
      @default_implementation
    )
  end
end
