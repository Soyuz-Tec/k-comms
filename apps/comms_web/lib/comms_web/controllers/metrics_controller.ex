defmodule CommsWeb.MetricsController do
  use CommsWeb, :controller

  alias CommsCore.Repo

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, CommsObservability.Metrics.render(queue_age()))
  end

  defp queue_age do
    sql = """
    SELECT COALESCE(
      EXTRACT(EPOCH FROM (NOW() - MIN(scheduled_at)))::double precision,
      0.0
    )
    FROM oban_jobs
    WHERE state IN ('available', 'scheduled', 'retryable')
    """

    case Ecto.Adapters.SQL.query(Repo, sql, []) do
      {:ok, %{rows: [[value]]}} -> value
      _ -> 0
    end
  end
end
