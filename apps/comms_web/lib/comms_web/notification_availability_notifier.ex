defmodule CommsWeb.NotificationAvailabilityNotifier do
  @behaviour CommsCore.Notifications.AvailabilityNotifier

  alias CommsCore.Notifications
  alias CommsCore.Notifications.Availability
  alias CommsWeb.Broadcast

  @impl true
  def notify(%Availability{} = availability) do
    if Process.whereis(CommsWeb.PubSub) do
      {:ok, unread_count} =
        Notifications.unread_count(%{
          tenant_id: availability.tenant_id,
          user_id: availability.user_id
        })

      Broadcast.user(availability.user_id, "notification.available.v1", %{
        notification_id: availability.notification_id,
        event_type: availability.event_type,
        conversation_id: availability.conversation_id,
        message_id: availability.message_id,
        unread_count: unread_count
      })
    end

    :ok
  end
end
