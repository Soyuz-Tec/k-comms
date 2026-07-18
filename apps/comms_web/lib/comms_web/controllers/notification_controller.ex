defmodule CommsWeb.NotificationController do
  use CommsWeb, :controller

  alias CommsCore.Notifications
  alias CommsWeb.IntegrationPresenter

  def index(conn, params) do
    with {:ok, intents} <- Notifications.list_intents(conn.assigns.current_subject, params) do
      json(conn, %{data: Enum.map(intents, &IntegrationPresenter.notification_intent/1)})
    end
  end

  def attempts(conn, params) do
    with {:ok, attempts} <- Notifications.list_attempts(conn.assigns.current_subject, params) do
      json(conn, %{data: Enum.map(attempts, &IntegrationPresenter.notification_attempt/1)})
    end
  end

  def retry(conn, %{"id" => id}) do
    with {:ok, intent} <- Notifications.retry_intent(id, conn.assigns.current_subject) do
      conn
      |> put_status(:accepted)
      |> json(%{data: IntegrationPresenter.notification_intent(intent)})
    end
  end
end
