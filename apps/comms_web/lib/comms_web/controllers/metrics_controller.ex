defmodule CommsWeb.MetricsController do
  use CommsWeb, :controller

  alias CommsCore.Repo

  @runtime_gauges_sql """
  SELECT
    COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(scheduled_at)))::double precision, 0.0),
    COUNT(*) FILTER (WHERE state IN ('available', 'scheduled', 'retryable')),
    COUNT(*) FILTER (WHERE state = 'discarded'),
    (SELECT COUNT(*) FROM outbox_events WHERE published_at IS NULL),
    (SELECT COUNT(*) FROM attachments WHERE status = 'quarantined'),
    (SELECT COUNT(*) FROM notification_intents WHERE status = 'failed'),
    (SELECT COUNT(*) FROM webhook_deliveries WHERE status = 'failed'),
    (SELECT COUNT(*) FROM attachments WHERE scan_status = 'failed')
  FROM oban_jobs
  """

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, CommsObservability.Metrics.render(runtime_gauges()))
  end

  defp runtime_gauges do
    case Ecto.Adapters.SQL.query(Repo, @runtime_gauges_sql, []) do
      {:ok,
       %{
         rows: [
           [
             age,
             pending,
             discarded,
             outbox,
             quarantined,
             notification_failures,
             webhook_failures,
             scan_failures
           ]
         ]
       }} ->
        %{
          queue_age_seconds: age,
          jobs_pending: pending,
          jobs_discarded: discarded,
          outbox_pending: outbox,
          attachments_quarantined: quarantined,
          notification_failures: notification_failures,
          webhook_failures: webhook_failures,
          attachment_scan_failures: scan_failures
        }

      _ ->
        %{}
    end
  end
end
