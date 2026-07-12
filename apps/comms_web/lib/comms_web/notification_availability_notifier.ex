defmodule CommsWeb.NotificationAvailabilityNotifier do
  @behaviour CommsCore.Notifications.AvailabilityNotifier

  alias CommsCore.InAppNotifications
  alias CommsCore.Notifications.Intent
  alias CommsWeb.{Broadcast, InAppNotificationPresenter}

  @impl true
  def notify(%Intent{} = intent) do
    if Process.whereis(CommsWeb.PubSub) do
      presented = InAppNotificationPresenter.notification(intent)

      {:ok, unread_count} =
        InAppNotifications.unread_count(%{
          tenant_id: intent.tenant_id,
          user_id: intent.user_id
        })

      Broadcast.user(intent.user_id, "notification.available.v1", %{
        notification_id: intent.id,
        event_type: intent.event_type,
        conversation_id: presented.conversation_id,
        message_id: presented.message_id,
        unread_count: unread_count
      })
    end

    :ok
  end
end
