defmodule CommsCore.Notifications.Projector do
  @moduledoc false

  alias CommsCore.Notifications.{
    Attempt,
    AttemptView,
    Availability,
    Delivery,
    Intent,
    IntentView,
    Preference,
    PreferenceView,
    PushSubscription,
    PushSubscriptionView
  }

  @recovery_event_type "account.password_recovery.requested.v1"

  def preference(%Preference{} = preference) do
    struct(PreferenceView, Map.take(Map.from_struct(preference), Map.keys(%PreferenceView{})))
  end

  def intent(%Intent{} = intent) do
    sensitive? = intent.event_type == @recovery_event_type

    %IntentView{
      id: intent.id,
      tenant_id: intent.tenant_id,
      user_id: intent.user_id,
      event_type: if(sensitive?, do: "sensitive", else: intent.event_type),
      channel: intent.channel,
      destination_hint: if(sensitive?, do: nil, else: destination_hint(intent)),
      payload: if(sensitive?, do: %{}, else: intent.payload || %{}),
      status: intent.status,
      attempt_count: intent.attempt_count,
      next_attempt_at: intent.next_attempt_at,
      delivered_at: intent.delivered_at,
      last_error_code: intent.last_error_code,
      read_at: intent.read_at,
      dismissed_at: intent.dismissed_at,
      inserted_at: intent.inserted_at,
      updated_at: intent.updated_at
    }
  end

  def attempt(%Attempt{} = attempt) do
    struct(AttemptView, Map.take(Map.from_struct(attempt), Map.keys(%AttemptView{})))
  end

  def push_subscription(%PushSubscription{} = subscription) do
    struct(
      PushSubscriptionView,
      Map.take(Map.from_struct(subscription), Map.keys(%PushSubscriptionView{}))
    )
  end

  def delivery(%Intent{} = intent) do
    struct(Delivery, Map.take(Map.from_struct(intent), Map.keys(%Delivery{})))
  end

  def availability(%Intent{} = intent) do
    %Availability{
      notification_id: intent.id,
      tenant_id: intent.tenant_id,
      user_id: intent.user_id,
      event_type: intent.event_type,
      conversation_id: safe_uuid(payload_value(intent.payload, "conversation_id")),
      message_id: safe_uuid(payload_value(intent.payload, "message_id"))
    }
  end

  defp destination_hint(%Intent{channel: :push}), do: nil

  defp destination_hint(%Intent{destination: destination}) when is_binary(destination) do
    case String.split(destination, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp destination_hint(_intent), do: nil

  defp payload_value(payload, key) when is_map(payload), do: Map.get(payload, key)
  defp payload_value(_payload, _key), do: nil

  defp safe_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> value
      :error -> nil
    end
  end

  defp safe_uuid(_value), do: nil
end
