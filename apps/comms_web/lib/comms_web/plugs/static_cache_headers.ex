defmodule CommsWeb.Plugs.StaticCacheHeaders do
  import Plug.Conn

  @hashed_asset ~r<\A/app/assets/[A-Za-z0-9._-]+-[A-Za-z0-9_-]{8,}\.(?:js|css)\z>
  @app_entry_paths ["/app/", "/app/index.html"]

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @app_entry_paths do
    register_before_send(conn, fn conn ->
      put_resp_header(conn, "cache-control", "no-store, max-age=0, must-revalidate")
    end)
  end

  def call(%Plug.Conn{request_path: "/app/k-comms-sw.js"} = conn, _opts) do
    register_before_send(conn, fn conn ->
      conn = put_resp_header(conn, "cache-control", "no-store, max-age=0, must-revalidate")

      if successful_static_response?(conn, "/app/k-comms-sw.js") do
        put_resp_header(conn, "service-worker-allowed", "/app/")
      else
        delete_resp_header(conn, "service-worker-allowed")
      end
    end)
  end

  def call(%Plug.Conn{request_path: "/app/manifest.webmanifest"} = conn, _opts) do
    register_before_send(conn, fn conn ->
      if successful_static_response?(conn, "/app/manifest.webmanifest") do
        put_resp_header(conn, "cache-control", "no-cache, max-age=0, must-revalidate")
      else
        put_resp_header(conn, "cache-control", "no-store, max-age=0, must-revalidate")
      end
    end)
  end

  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if Regex.match?(@hashed_asset, path) do
      register_before_send(conn, fn conn ->
        if successful_static_response?(conn, path) do
          put_resp_header(conn, "cache-control", "public, max-age=31536000, immutable")
        else
          put_resp_header(conn, "cache-control", "no-store, max-age=0, must-revalidate")
        end
      end)
    else
      conn
    end
  end

  defp successful_static_response?(%Plug.Conn{status: status} = conn, path)
       when status in 200..299 do
    expected = MIME.from_path(path)

    case get_resp_header(conn, "content-type") do
      [actual | _rest] ->
        actual
        |> String.split(";", parts: 2)
        |> List.first()
        |> Kernel.==(expected)

      [] ->
        false
    end
  end

  defp successful_static_response?(_conn, _path), do: false
end
