defmodule CommsWeb.StatusController do
  use CommsWeb, :controller

  alias CommsCore.Notifications, as: NotificationDelivery
  alias CommsIntegrations.Audio.LiveKitToken
  alias CommsIntegrations.{Notifications, Scanner, Webhooks}

  def show(conn, _params) do
    calls_available = available?(LiveKitToken.status())

    json(conn, %{
      service: "k-comms",
      version: to_string(Application.spec(:comms_web, :vsn)),
      status: "operational",
      capabilities: %{
        administration: true,
        audio_calls: calls_available,
        video_calls: calls_available,
        attachment_scanning: available?(Scanner.status()),
        bootstrap: Application.get_env(:comms_web, :allow_bootstrap, false),
        notifications: available?(Notifications.status()),
        push_notifications: available?(NotificationDelivery.push_status()),
        realtime: true,
        webhooks: available?(Webhooks.status())
      }
    })
  end

  defp available?(%{status: status}) when status in [:available, "available"], do: true
  defp available?(_status), do: false
end
