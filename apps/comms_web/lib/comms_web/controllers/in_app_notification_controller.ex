defmodule CommsWeb.InAppNotificationController do
  use CommsWeb, :controller

  alias CommsCore.Notifications
  alias CommsWeb.InAppNotificationPresenter

  def index(conn, params) do
    with {:ok, result} <- Notifications.list_in_app(conn.assigns.current_subject, params) do
      json(conn, %{
        data: Enum.map(result.notifications, &InAppNotificationPresenter.notification/1),
        meta: %{unread_count: result.unread_count}
      })
    end
  end

  def unread_count(conn, _params) do
    with {:ok, count} <- Notifications.unread_count(conn.assigns.current_subject) do
      json(conn, %{data: %{unread_count: count}})
    end
  end

  def mark_read(conn, %{"id" => id}) do
    with {:ok, intent} <- Notifications.mark_in_app_read(id, conn.assigns.current_subject) do
      json(conn, %{data: InAppNotificationPresenter.notification(intent)})
    end
  end

  def dismiss(conn, %{"id" => id}) do
    with {:ok, intent} <- Notifications.dismiss_in_app(id, conn.assigns.current_subject) do
      json(conn, %{data: InAppNotificationPresenter.notification(intent)})
    end
  end

  def mark_all_read(conn, _params) do
    with {:ok, result} <- Notifications.mark_all_in_app_read(conn.assigns.current_subject) do
      json(conn, %{data: result})
    end
  end
end
