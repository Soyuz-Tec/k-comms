defmodule CommsWeb.AuditExportController do
  use CommsWeb, :controller

  alias CommsCore.AuditExport

  def create(conn, params) do
    with {:ok, export} <- AuditExport.export(params, conn.assigns.current_subject) do
      conn
      |> put_resp_content_type("text/csv", "utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{export.filename}"))
      |> put_resp_header("x-export-row-count", Integer.to_string(export.count))
      |> put_resp_header("x-export-truncated", to_string(export.truncated))
      |> send_resp(:ok, export.csv)
    end
  end
end
