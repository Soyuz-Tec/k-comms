defmodule CommsWeb.DirectoryController do
  use CommsWeb, :controller

  alias CommsCore.Accounts

  def index(conn, params) do
    with {:ok, result} <-
           Accounts.list_directory_views(params, conn.assigns.current_subject) do
      json(conn, %{
        data: Enum.map(result.people, &Presenter.directory_person/1),
        page: %{next_cursor: result.next_cursor}
      })
    end
  end
end
