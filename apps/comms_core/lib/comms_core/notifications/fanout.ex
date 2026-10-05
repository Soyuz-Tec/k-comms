defmodule CommsCore.Notifications.Fanout do
  @moduledoc false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.NotificationRecipient
  alias CommsCore.Conversations

  alias CommsCore.Notifications.{
    Intents,
    Preference,
    Preferences,
    Projector,
    PushSubscriptions
  }

  alias CommsCore.Outbox.Event

  @meeting_event_types ~w(meeting.scheduled.v1 meeting.updated.v1 meeting.cancelled.v1 meeting.reminder.v1)

  def enqueue_for_event(%Event{event_type: "message.created.v1"} = event, notify_availability)
      when is_function(notify_availability, 1) do
    sender_user_id = payload_value(event.payload, "sender_user_id")
    conversation_id = payload_value(event.payload, "conversation_id")

    excluded_user_ids =
      [sender_user_id | mentioned_user_ids(event)]
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    recipient_ids =
      event.tenant_id
      |> Conversations.active_member_ids(conversation_id)
      |> Enum.reject(&MapSet.member?(excluded_user_ids, &1))

    enqueue_recipient_events(event, recipient_ids, notify_availability)
  end

  def enqueue_for_event(%Event{event_type: "mention.created.v1"} = event, notify_availability)
      when is_function(notify_availability, 1) do
    conversation_id = payload_value(event.payload, "conversation_id")
    sender_user_id = payload_value(event.payload, "sender_user_id")

    mentioned_user_ids =
      event
      |> mentioned_user_ids()
      |> Enum.reject(&(&1 == sender_user_id))
      |> MapSet.new()

    recipient_ids =
      event.tenant_id
      |> Conversations.active_member_ids(conversation_id)
      |> Enum.filter(&MapSet.member?(mentioned_user_ids, &1))

    enqueue_recipient_events(event, recipient_ids, notify_availability)
  end

  def enqueue_for_event(%Event{event_type: event_type} = event, notify_availability)
      when event_type in @meeting_event_types and is_function(notify_availability, 1) do
    recipient_ids =
      Conversations.active_member_ids(
        event.tenant_id,
        payload_value(event.payload, "conversation_id")
      )

    enqueue_recipient_events(event, recipient_ids, notify_availability)
  end

  def enqueue_for_event(%Event{}, notify_availability)
      when is_function(notify_availability, 1),
      do: :ok

  defp enqueue_recipient_events(%Event{} = event, user_ids, notify_availability) do
    recipients = Accounts.resolve_notification_recipients(event.tenant_id, user_ids)
    preferences = Preferences.by_recipient_id(event.tenant_id, recipients)

    Enum.reduce_while(recipients, :ok, fn recipient, :ok ->
      case enqueue_recipient_event(
             event,
             recipient,
             Map.get(preferences, recipient.user_id),
             notify_availability
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp enqueue_recipient_event(
         %Event{} = event,
         %NotificationRecipient{} = recipient,
         preference,
         notify_availability
       ) do
    muted = preference && event.event_type in preference.muted_event_types

    if muted do
      :ok
    else
      with :ok <- maybe_create_in_app(event, recipient, preference, notify_availability),
           :ok <- maybe_create_email(event, recipient, preference),
           :ok <- maybe_create_push(event, recipient, preference) do
        :ok
      end
    end
  end

  defp maybe_create_in_app(event, recipient, preference, notify_availability) do
    if is_nil(preference) or preference.in_app_enabled do
      now = now()

      attrs = base_intent_attrs(event, recipient, :in_app, recipient.user_id)
      attrs = Map.merge(attrs, %{status: :delivered, delivered_at: now, next_attempt_at: now})

      case Intents.create_without_job(attrs) do
        {:ok, intent, status} when status in [:created, :duplicate] ->
          notify_availability.(Projector.availability(intent))

        {:error, _} = error ->
          error
      end
    else
      :ok
    end
  end

  defp maybe_create_email(event, recipient, preference) do
    if is_nil(preference) or preference.email_enabled do
      case Intents.create(base_intent_attrs(event, recipient, :email, recipient.email)) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp maybe_create_push(event, recipient, %Preference{push_enabled: true}) do
    event.tenant_id
    |> PushSubscriptions.active_subscription_ids(recipient.user_id)
    |> Enum.reduce_while(:ok, fn subscription, :ok ->
      attrs =
        event
        |> base_intent_attrs(recipient, :push, subscription.id, subscription.id)
        |> Map.merge(%{
          push_subscription_id: subscription.id,
          push_subscription_version: subscription.version
        })

      case Intents.create(attrs) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_create_push(_event, _recipient, _preference), do: :ok

  defp base_intent_attrs(event, recipient, channel, destination, idempotency_target \\ nil) do
    {title, body} = notification_copy(event.event_type)
    target_suffix = if is_binary(idempotency_target), do: ":#{idempotency_target}", else: ""

    %{
      tenant_id: event.tenant_id,
      user_id: recipient.user_id,
      event_type: event.event_type,
      channel: channel,
      destination: destination,
      idempotency_key: "outbox:#{event.id}:user:#{recipient.user_id}:#{channel}#{target_suffix}",
      payload: %{
        "title" => title,
        "body" => body,
        "conversation_id" => payload_value(event.payload, "conversation_id"),
        "message_id" =>
          if(event.event_type in @meeting_event_types, do: nil, else: event.aggregate_id),
        "meeting_id" => payload_value(event.payload, "meeting_id"),
        "occurrence_id" => payload_value(event.payload, "occurrence_id"),
        "starts_at" => payload_value(event.payload, "starts_at"),
        "sender_user_id" => payload_value(event.payload, "sender_user_id"),
        "event_id" => event.id,
        "aggregate_id" => event.aggregate_id,
        "aggregate_type" => event.aggregate_type
      }
    }
  end

  defp notification_copy("mention.created.v1"),
    do: {"New mention", "You were mentioned in K-Comms."}

  defp notification_copy("meeting.scheduled.v1"),
    do: {"Meeting scheduled", "A meeting was scheduled in your conversation."}

  defp notification_copy("meeting.updated.v1"),
    do: {"Meeting updated", "A meeting in your conversation has changed."}

  defp notification_copy("meeting.cancelled.v1"),
    do: {"Meeting cancelled", "A meeting in your conversation was cancelled."}

  defp notification_copy("meeting.reminder.v1"),
    do: {"Meeting reminder", "A meeting in your conversation starts soon."}

  defp notification_copy(_), do: {"New message", "You have a new message in K-Comms."}

  defp payload_value(payload, key),
    do:
      Map.get(payload || %{}, key) ||
        Enum.find_value(payload || %{}, fn {name, value} ->
          if to_string(name) == key, do: value
        end)

  defp mentioned_user_ids(event) do
    case payload_value(event.payload, "mentioned_user_ids") do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
