defmodule CommsWeb.StatusController do
  use CommsWeb, :controller

  alias CommsCore.Administration
  alias CommsCore.Notifications, as: NotificationDelivery
  alias CommsIntegrations.Audio.LiveKitReadiness
  alias CommsIntegrations.{Notifications, Scanner, Webhooks}

  def show(conn, _params) do
    calls_available = available?(LiveKitReadiness.status())

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
        guest_links: true,
        instant_rooms: instant_rooms_available?(),
        notifications: available?(Notifications.status()),
        push_notifications: available?(NotificationDelivery.push_status()),
        realtime: true,
        webhooks: available?(Webhooks.status())
      }
    })
  end

  defp available?(%{status: status}) when status in [:available, "available"], do: true
  defp available?(_status), do: false

  defp instant_rooms_available? do
    with true <- Application.get_env(:comms_core, :instant_rooms_enabled, false),
         slug when is_binary(slug) <- Application.get_env(:comms_core, :instant_room_tenant_slug),
         true <- String.trim(slug) != "",
         {:ok, _tenant} <- Administration.active_tenant_by_slug(slug) do
      true
    else
      _ -> false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
