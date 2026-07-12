defmodule CommsWeb.Plugs.Cors do
  import Plug.Conn

  @allow_headers "authorization,content-type,idempotency-key,x-request-id"
  @allow_methods "GET,POST,PUT,PATCH,DELETE,OPTIONS"

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = List.first(get_req_header(conn, "origin"))
    allowed = allowed_origin?(origin)

    conn =
      if allowed do
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-credentials", "true")
        |> put_resp_header("access-control-allow-headers", @allow_headers)
        |> put_resp_header("access-control-allow-methods", @allow_methods)
        |> put_resp_header("access-control-max-age", "600")
        |> put_resp_header("vary", "origin")
      else
        conn
      end

    if conn.method == "OPTIONS" do
      if allowed do
        conn |> send_resp(:no_content, "") |> halt()
      else
        conn |> send_resp(:forbidden, "") |> halt()
      end
    else
      conn
    end
  end

  defp allowed_origin?(nil), do: false

  defp allowed_origin?(origin) do
    origin in Application.get_env(:comms_web, :cors_origins, [])
  end
end
