defmodule CommsWeb.NotificationPreferenceController do
  use CommsWeb, :controller

  alias CommsCore.Notifications
  alias CommsWeb.IntegrationPresenter

  def show(conn, _params) do
    preference = Notifications.get_preferences(conn.assigns.current_subject)
    json(conn, %{data: IntegrationPresenter.notification_preference(preference)})
  end

  def update(conn, params) do
    with {:ok, preference} <-
           Notifications.update_preferences(params, conn.assigns.current_subject) do
      json(conn, %{data: IntegrationPresenter.notification_preference(preference)})
    end
  end
end
