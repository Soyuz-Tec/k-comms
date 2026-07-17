defmodule CommsWeb.MeController do
  use CommsWeb, :controller

  alias CommsCore.Accounts

  def show(conn, _params) do
    with {:ok, capabilities} <-
           CommsCore.Administration.member_capabilities(conn.assigns.current_subject) do
      json(conn, %{
        tenant: Presenter.tenant(conn.assigns.current_tenant),
        user: Presenter.identity_user(conn.assigns.current_user),
        device: Presenter.device(conn.assigns.current_device),
        capabilities: capabilities
      })
    end
  end

  def users(conn, _params) do
    users = Accounts.list_tenant_user_views(conn.assigns.current_subject)
    json(conn, %{data: Enum.map(users, &Presenter.user/1)})
  end
end
