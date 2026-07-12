defmodule CommsWeb.AdminTenantController do
  use CommsWeb, :controller

  alias CommsCore.Administration

  def show(conn, _params) do
    with {:ok, result} <- Administration.get_tenant_settings(conn.assigns.current_subject) do
      json(conn, %{
        data: %{
          tenant: Presenter.tenant(result.tenant),
          settings: Presenter.tenant_settings(result.settings),
          usage: Presenter.tenant_usage(result.usage)
        }
      })
    end
  end

  def update(conn, params) do
    with {:ok, result} <-
           Administration.update_tenant_settings(params, conn.assigns.current_subject) do
      json(conn, %{
        data: %{
          tenant: Presenter.tenant(result.tenant),
          settings: Presenter.tenant_settings(result.settings),
          usage: Presenter.tenant_usage(result.usage)
        }
      })
    end
  end
end
