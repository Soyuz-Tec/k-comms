defmodule CommsWeb.SpaController do
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def index(conn, %{"path" => ["api" | _rest]}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      404,
      Jason.encode!(%{error: %{code: "not_found", detail: "API route not found"}})
    )
  end

  def index(conn, _params) do
    index_path = Application.app_dir(:comms_web, "priv/static/app/index.html")

    if File.exists?(index_path) do
      send_file(conn, 200, index_path)
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(
        200,
        "<main><h1>K-Comms API</h1><p>Build clients/web to install the web client.</p></main>"
      )
    end
  end
end
