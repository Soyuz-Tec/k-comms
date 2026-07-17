defmodule CommsWeb.Plugs.SecurityHeaders do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    connect_sources =
      Application.get_env(:comms_web, :csp_connect_sources, ["'self'"])
      |> Enum.join(" ")

    content_security_policy =
      "default-src 'self'; " <>
        "base-uri 'self'; frame-ancestors 'none'; form-action 'self'; " <>
        "object-src 'none'; script-src 'self'; style-src 'self'; " <>
        "img-src 'self' data: blob:; font-src 'self'; connect-src #{connect_sources}"

    conn
    |> put_resp_header("content-security-policy", content_security_policy)
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("permissions-policy", "camera=(self), microphone=(self), geolocation=()")
    |> maybe_hsts()
  end

  defp maybe_hsts(conn) do
    if Application.get_env(:comms_web, :hsts, false) do
      put_resp_header(conn, "strict-transport-security", "max-age=31536000; includeSubDomains")
    else
      conn
    end
  end
end
