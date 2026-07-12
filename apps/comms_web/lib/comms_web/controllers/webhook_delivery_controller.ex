defmodule CommsWeb.WebhookDeliveryController do
  use CommsWeb, :controller

  alias CommsCore.Integrations
  alias CommsWeb.IntegrationPresenter

  def index(conn, params) do
    with {:ok, deliveries} <-
           Integrations.list_deliveries(conn.assigns.current_subject, params) do
      json(conn, %{data: Enum.map(deliveries, &IntegrationPresenter.webhook_delivery/1)})
    end
  end

  def replay(conn, %{"id" => id}) do
    with {:ok, delivery} <- Integrations.replay_delivery(id, conn.assigns.current_subject) do
      conn
      |> put_status(:accepted)
      |> json(%{data: IntegrationPresenter.webhook_delivery(delivery)})
    end
  end
end
