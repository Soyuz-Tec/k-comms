defmodule CommsWeb.Plugs.RequireSecureTransport do
  @moduledoc """
  Disables credential and media operations on an explicit clear-text LAN release.

  Loopback development remains available, and ordinary production deployments
  already require HTTPS at configuration validation. This guard is the
  server-side backstop for the controlled LAN text-only qualification mode.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:comms_web, :insecure_lan_release, false) and
         conn.scheme != :https do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        :upgrade_required,
        Jason.encode!(%{
          error: %{
            code: "secure_transport_required",
            detail: "This operation requires a trusted HTTPS connection"
          }
        })
      )
      |> halt()
    else
      conn
    end
  end
end
