defmodule CommsCore.Notifications.AvailabilityNotifier.Contract do
  @moduledoc """
  Implementation contract for the notification-availability technical API.
  """

  alias CommsCore.Notifications.Availability

  @callback notify(Availability.t()) :: :ok | {:error, term()}
end
