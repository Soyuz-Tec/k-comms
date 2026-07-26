defmodule CommsWeb.Plugs.RequireSecureTransport do
  @moduledoc """
  Requires an effective HTTPS connection for transport-sensitive release modes.

  Loopback development remains available. The guard is the server-side
  backstop for both the controlled LAN text-only mode and a trusted-edge local
  release whose terminating proxy has established the effective HTTPS scheme.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if not secure_actions_available?(conn) do
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

  @doc false
  def secure_actions_available?(%Plug.Conn{scheme: :https}), do: true

  def secure_actions_available?(%Plug.Conn{}) do
    not secure_transport_required?()
  end

  defp secure_transport_required? do
    Application.get_env(:comms_web, :insecure_lan_release, false) or
      Application.get_env(:comms_web, :secure_transport_required, false)
  end
end
