defmodule CommsWeb.ServiceAccountController do
  use CommsWeb, :controller

  alias CommsCore.ServiceAccounts
  alias CommsWeb.ServiceAccountPresenter

  def index(conn, _params) do
    with {:ok, accounts} <- ServiceAccounts.list_views(conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(accounts, &ServiceAccountPresenter.service_account/1)})
    end
  end

  def create(conn, params) do
    with {:ok, result} <- ServiceAccounts.create_view(params, conn.assigns.current_subject) do
      conn
      |> put_status(:created)
      |> json(%{
        data: ServiceAccountPresenter.service_account(result.service_account),
        credential: result.credential,
        credential_notice: "Store this service credential now. It will not be shown again."
      })
    end
  end

  def rotate(conn, %{"id" => id} = params) do
    with {:ok, result} <- ServiceAccounts.rotate_view(id, params, conn.assigns.current_subject) do
      json(conn, %{
        data: ServiceAccountPresenter.service_account(result.service_account),
        credential: result.credential,
        credential_notice:
          "Store this service credential now. The previous credential is invalid."
      })
    end
  end

  def revoke(conn, %{"id" => id} = params) do
    with {:ok, account} <- ServiceAccounts.revoke_view(id, params, conn.assigns.current_subject) do
      json(conn, %{data: ServiceAccountPresenter.service_account(account)})
    end
  end
end
