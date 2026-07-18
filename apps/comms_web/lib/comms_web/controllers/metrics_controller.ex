defmodule CommsWeb.MetricsController do
  use CommsWeb, :controller

  alias CommsCore.Operations

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, CommsObservability.Metrics.render(Operations.runtime_gauges()))
  end
end
