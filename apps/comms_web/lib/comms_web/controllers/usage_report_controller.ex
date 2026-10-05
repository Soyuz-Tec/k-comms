defmodule CommsWeb.UsageReportController do
  use CommsWeb, :controller
  alias CommsWeb.UsageReports

  def index(conn, params) do
    case UsageReports.json(params, conn.assigns.current_subject) do
      {:ok, body} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def export(conn, params) do
    case UsageReports.export(params, conn.assigns.current_subject) do
      {:ok, body, receipt} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_content_type("text/csv")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"usage-#{receipt.from}-#{receipt.through}.csv\""
        )
        |> put_resp_header("x-usage-from", receipt.from)
        |> put_resp_header("x-usage-through", receipt.through)
        |> put_resp_header("x-usage-time-zone", "UTC")
        |> put_resp_header("x-usage-observed-at", receipt.observed_at)
        |> put_resp_header(
          "x-usage-unavailable-sources",
          Integer.to_string(receipt.unavailable_sources)
        )
        |> send_resp(200, body)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp error(conn, reason) when reason in [:invalid_usage_query, :usage_report_too_large] do
    conn
    |> put_status(422)
    |> json(%{
      error: %{
        code: Atom.to_string(reason),
        detail: "Choose an inclusive UTC date range of at most 31 days."
      }
    })
  end

  defp error(conn, :usage_report_unavailable) do
    conn
    |> put_status(503)
    |> json(%{
      error: %{
        code: "usage_report_unavailable",
        detail: "Usage reporting is temporarily unavailable."
      }
    })
  end

  defp error(conn, reason), do: CommsWeb.FallbackController.call(conn, {:error, reason})
end
