defmodule CommsWeb.AuditController do
  use CommsWeb, :controller

  alias CommsCore.Administration

  def index(conn, params) do
    with {:ok, result} <- Administration.list_audit_events(params, conn.assigns.current_subject) do
      data = Enum.map(result.events, &Presenter.audit_event/1)

      json(conn, %{
        data: data,
        page: %{limit: result.limit, next_cursor: result.next_cursor}
      })
    end
  end
end
