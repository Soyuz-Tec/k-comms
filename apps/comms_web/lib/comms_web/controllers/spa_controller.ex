defmodule CommsWeb.SpaController do
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def canonical_app(conn, _params) do
    query = if conn.query_string == "", do: "", else: "?#{conn.query_string}"

    conn
    |> put_resp_header("cache-control", "no-store, max-age=0, must-revalidate")
    |> put_resp_header("location", "/app/#{query}")
    |> send_resp(308, "")
  end

  def index(conn, %{"path" => ["api" | _rest]}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      404,
      Jason.encode!(%{error: %{code: "not_found", detail: "API route not found"}})
    )
  end

  def index(conn, %{"path" => ["app", "assets" | _rest]}), do: missing_static(conn)
  def index(conn, %{"path" => ["app", "icons" | _rest]}), do: missing_static(conn)

  def index(conn, %{"path" => ["app", file]})
      when file in [
             "k-comms-sw.js",
             "manifest.webmanifest",
             "offline.css",
             "offline.html"
           ],
      do: missing_static(conn)

  def index(conn, _params) do
    index_path = Application.app_dir(:comms_web, "priv/static/app/index.html")

    if File.exists?(index_path) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index_path)
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(
        200,
        "<main><h1>K-Comms API</h1><p>Build clients/web to install the web client.</p></main>"
      )
    end
  end

  defp missing_static(conn) do
    conn
    |> put_resp_header("cache-control", "no-store, max-age=0, must-revalidate")
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Static application asset not found")
  end
end
