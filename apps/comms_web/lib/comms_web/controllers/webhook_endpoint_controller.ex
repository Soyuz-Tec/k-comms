defmodule CommsWeb.WebhookEndpointController do
  use CommsWeb, :controller

  alias CommsCore.Integrations
  alias CommsIntegrations.Webhooks
  alias CommsWeb.IntegrationPresenter

  def index(conn, _params) do
    with {:ok, endpoints} <- Integrations.list_endpoint_views(conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(endpoints, &IntegrationPresenter.webhook_endpoint/1)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, endpoint} <- Integrations.get_endpoint_view(id, conn.assigns.current_subject) do
      json(conn, %{data: IntegrationPresenter.webhook_endpoint(endpoint)})
    end
  end

  def create(conn, params) do
    with :ok <- validate_destination(params),
         {:ok, %{endpoint: endpoint, secret: secret}} <-
           Integrations.create_endpoint_view(params, conn.assigns.current_subject) do
      conn
      |> put_status(:created)
      |> json(%{
        data: IntegrationPresenter.webhook_endpoint(endpoint),
        secret: secret,
        secret_notice: "Store this signing secret now. It will not be shown again."
      })
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- validate_destination(params),
         {:ok, endpoint} <-
           Integrations.update_endpoint_view(id, params, conn.assigns.current_subject) do
      json(conn, %{data: IntegrationPresenter.webhook_endpoint(endpoint)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _endpoint} <- Integrations.disable_endpoint_view(id, conn.assigns.current_subject) do
      send_resp(conn, :no_content, "")
    end
  end

  def rotate_secret(conn, %{"id" => id}) do
    with {:ok, %{endpoint: endpoint, secret: secret}} <-
           Integrations.rotate_secret_view(id, conn.assigns.current_subject) do
      json(conn, %{
        data: IntegrationPresenter.webhook_endpoint(endpoint),
        secret: secret,
        secret_notice: "Store this signing secret now. It will not be shown again."
      })
    end
  end

  defp validate_destination(params) do
    case Map.get(params, "url") || Map.get(params, :url) do
      nil ->
        :ok

      url ->
        case Webhooks.validate_configured_destination(url) do
          :ok -> :ok
          {:error, _} -> {:error, :invalid_webhook_destination}
        end
    end
  end
end
