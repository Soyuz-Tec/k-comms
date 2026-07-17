defmodule CommsWeb.AdminTenantController do
  use CommsWeb, :controller

  alias CommsCore.{Administration, Operations}

  def show(conn, _params) do
    subject = conn.assigns.current_subject

    with {:ok, result} <- Administration.get_tenant_settings_view(subject),
         {:ok, usage} <- Operations.tenant_admission_usage(subject) do
      json(conn, %{
        data: %{
          tenant: Presenter.tenant(result.tenant),
          settings: Presenter.tenant_settings(result.settings),
          usage: Presenter.tenant_usage(usage)
        }
      })
    end
  end

  def update(conn, params) do
    subject = conn.assigns.current_subject

    with {:ok, result} <-
           Administration.update_tenant_settings_view(params, subject),
         {:ok, usage} <- Operations.tenant_admission_usage(subject) do
      json(conn, %{
        data: %{
          tenant: Presenter.tenant(result.tenant),
          settings: Presenter.tenant_settings(result.settings),
          usage: Presenter.tenant_usage(usage)
        }
      })
    end
  end
end
