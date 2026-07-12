defmodule CommsWeb.MeController do
  use CommsWeb, :controller

  alias CommsCore.Accounts

  def show(conn, _params) do
    json(conn, %{
      tenant: Presenter.tenant(conn.assigns.current_tenant),
      user: Presenter.user(conn.assigns.current_user),
      device: Presenter.device(conn.assigns.current_device)
    })
  end

  def users(conn, _params) do
    users = Accounts.list_tenant_users(conn.assigns.current_subject)
    json(conn, %{data: Enum.map(users, &Presenter.user/1)})
  end
end
