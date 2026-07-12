defmodule CommsWeb.UserController do
  use CommsWeb, :controller

  alias CommsCore.Accounts

  def create(conn, params) do
    with {:ok, user} <- Accounts.create_user(params, conn.assigns.current_subject) do
      conn
      |> put_status(:created)
      |> json(%{data: Presenter.user(user)})
    end
  end
end
