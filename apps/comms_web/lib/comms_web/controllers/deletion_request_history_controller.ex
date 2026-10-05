defmodule CommsWeb.DeletionRequestHistoryController do
  use CommsWeb, :controller
  alias CommsCore.Governance

  plug(:private_history_response)

  def index(conn, %{"id" => id} = params) do
    case Governance.deletion_request_timeline(id, params, conn.assigns.current_subject) do
      {:ok, timeline} -> json(conn, %{data: Presenter.deletion_request_timeline(timeline)})
      error -> history_error(conn, error)
    end
  end

  def export(conn, %{"id" => id} = params) do
    case Governance.export_deletion_request_history(id, params, conn.assigns.current_subject) do
      {:ok, result} ->
        conn
        |> put_resp_content_type("text/csv", "utf-8")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="deletion-request-history.csv")
        )
        |> put_resp_header("x-export-row-count", Integer.to_string(result.count))
        |> put_resp_header("x-export-truncated", to_string(result.truncated))
        |> put_resp_header("x-export-maximum-rows", Integer.to_string(result.maximum_rows))
        |> put_resp_header("x-history-snapshot", result.snapshot)
        |> put_resp_header("x-history-coverage", Atom.to_string(result.coverage.state))
        |> put_resp_header("x-history-retained-only", "true")
        |> put_resp_header("x-history-observed-at", DateTime.to_iso8601(result.observed_at))
        |> send_resp(200, result.csv)

      error ->
        history_error(conn, error)
    end
  end

  defp private_history_response(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp history_error(conn, {:error, reason})
       when reason in [:invalid_history_cursor, :invalid_history_limit] do
    conn
    |> put_status(422)
    |> json(%{
      error: %{
        code: Atom.to_string(reason),
        detail: "The request history cursor or limit is invalid; reload the timeline"
      }
    })
  end

  defp history_error(conn, {:error, :history_unavailable}) do
    conn
    |> put_status(503)
    |> json(%{
      error: %{code: "history_unavailable", detail: "Request history is temporarily unavailable"}
    })
  end

  defp history_error(_conn, error), do: error
end
