defmodule CommsWeb.StatusController do
  use CommsWeb, :controller

  alias CommsCore.Administration
  alias CommsCore.Notifications, as: NotificationDelivery
  alias CommsIntegrations.Audio.LiveKitReadiness
  alias CommsIntegrations.{Notifications, Scanner, Webhooks}
  alias CommsWeb.Plugs.RequireSecureTransport

  def show(conn, _params) do
    calls_available = available?(LiveKitReadiness.status())
    secure_actions_available = secure_actions_available?(conn)

    json(conn, %{
      service: "k-comms",
      version: to_string(Application.spec(:comms_web, :vsn)),
      status: "operational",
      capabilities: %{
        administration: true,
        audio_calls: calls_available,
        video_calls: calls_available,
        whiteboards: true,
        attachment_scanning: available?(Scanner.status()),
        bootstrap: Application.get_env(:comms_web, :allow_bootstrap, false),
        guest_links: true,
        immersive_mode: immersive_mode_available?(),
        instant_rooms: instant_rooms_available?(),
        notifications: available?(Notifications.status()),
        private_rooms: secure_actions_available and private_rooms_configured?(),
        push_notifications: available?(NotificationDelivery.push_status()),
        realtime: true,
        secure_account_actions: secure_actions_available,
        secure_media_actions: secure_actions_available,
        webhooks: available?(Webhooks.status())
      }
    })
  end

  # The deployment-side half of immersive eligibility: a kill switch that can
  # retire the surface for every tenant at once without a client release. The
  # tenant-side half lives in member_capabilities/1; a client is eligible only
  # when both say yes.
  defp immersive_mode_available? do
    Application.get_env(:comms_web, :immersive_mode_enabled, false) == true
  end

  defp available?(%{status: status}) when status in [:available, "available"], do: true
  defp available?(_status), do: false

  defp secure_actions_available?(conn) do
    RequireSecureTransport.secure_actions_available?(conn)
  end

  # This is a read-only configuration preflight, not provider health or crypto
  # qualification. In particular, status must never provision a Matrix identity.
  defp private_rooms_configured? do
    with true <- Application.get_env(:comms_core, :private_rooms_enabled, false) == true,
         true <-
           Application.get_env(:comms_core, :matrix_client_provisioning_enabled, false) == true,
         %{issuer: issuer, server_name: server, control_user_id: control} <-
           Application.get_env(:comms_core, :matrix_identity_provider),
         true <- is_binary(issuer) and is_binary(server) and server != "",
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
         when is_binary(host) and host != "" and path in [nil, "", "/"] <- URI.parse(issuer),
         true <- is_binary(control) and String.ends_with?(control, ":" <> server) do
      Enum.all?([:matrix_provisioning_adapter, :private_room_control_adapter], fn key ->
        adapter = Application.get_env(:comms_core, key)

        is_atom(adapter) and Code.ensure_loaded?(adapter) and
          function_exported?(adapter, :execute, 2)
      end)
    else
      _ -> false
    end
  end

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
