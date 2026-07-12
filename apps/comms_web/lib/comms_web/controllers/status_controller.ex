defmodule CommsWeb.StatusController do
  use CommsWeb, :controller

  alias CommsCore.PushSubscriptions
  alias CommsIntegrations.{Notifications, Scanner, Webhooks}

  def show(conn, _params) do
    json(conn, %{
      service: "k-comms",
      version: to_string(Application.spec(:comms_web, :vsn)),
      status: "operational",
      capabilities: %{
        administration: true,
        attachment_scanning: available?(Scanner.status()),
        bootstrap: Application.get_env(:comms_web, :allow_bootstrap, false),
        notifications: available?(Notifications.status()),
        push_notifications: available?(PushSubscriptions.status()),
        realtime: true,
        webhooks: available?(Webhooks.status())
      }
    })
  end

  defp available?(%{status: status}) when status in [:available, "available"], do: true
  defp available?(_status), do: false
end
