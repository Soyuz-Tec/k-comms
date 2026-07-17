defmodule CommsWorkers.NotificationWorker do
  use Oban.Worker, queue: :notifications, max_attempts: 10

  alias CommsCore.Notifications
  alias CommsCore.Notifications.Delivery
  alias CommsCore.PasswordRecovery
  alias CommsIntegrations.Notifications, as: Provider

  @recovery_event_type "account.password_recovery.requested.v1"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"intent_id" => intent_id}}) do
    case Notifications.claim_intent(intent_id) do
      {:ok, {:already_delivered, _intent}} ->
        :ok

      {:ok, %Delivery{} = intent} ->
        result = deliver(intent)

        case Notifications.record_delivery(intent, result) do
          {:ok, _updated} ->
            :ok = record_push_result(intent, result)
            worker_result(result)

          {:error, :stale_delivery_claim} ->
            :ok

          {:error, reason} ->
            {:error, safe_reason(reason)}
        end

      {:error, :not_found} ->
        {:discard, :intent_not_found}

      {:error, :not_claimable} ->
        {:snooze, 30}

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_), do: {:discard, :intent_id_required}

  defp deliver(%Delivery{event_type: @recovery_event_type} = intent) do
    recovery = %{
      tenant_id: intent.tenant_id,
      user_id: intent.user_id,
      recovery_request_id: Map.get(intent.payload, "recovery_request_id")
    }

    case PasswordRecovery.materialize_notification(recovery) do
      {:ok, delivery} -> Provider.deliver(provider_request(intent, delivery))
      {:error, reason} -> {:error, :permanent, safe_reason(reason)}
    end
  end

  defp deliver(
         %Delivery{
           channel: :push,
           push_subscription_id: subscription_id,
           push_subscription_version: version
         } = intent
       )
       when is_binary(subscription_id) and is_integer(version) do
    case Notifications.materialize_push_destination(subscription_id, version, intent.tenant_id) do
      {:ok, destination} ->
        Provider.deliver(provider_request(intent, %{destination: destination}))

      {:error, reason} ->
        {:error, :permanent, safe_reason(reason)}
    end
  end

  defp deliver(%Delivery{channel: :push}),
    do: {:error, :permanent, :push_subscription_stale}

  defp deliver(%Delivery{} = intent), do: Provider.deliver(provider_request(intent, %{}))

  defp record_push_result(
         %Delivery{
           channel: :push,
           push_subscription_id: subscription_id,
           push_subscription_version: version
         },
         result
       )
       when is_binary(subscription_id) and is_integer(version) do
    Notifications.record_push_provider_result(subscription_id, version, result)
  end

  defp record_push_result(_intent, _result), do: :ok

  defp provider_request(intent, overrides) do
    %{
      tenant_id: intent.tenant_id,
      user_id: intent.user_id,
      event_type: intent.event_type,
      channel: intent.channel,
      destination: Map.get(overrides, :destination, intent.destination),
      payload: Map.get(overrides, :payload, intent.payload),
      idempotency_key: intent.idempotency_key
    }
  end

  defp worker_result(:ok), do: :ok
  defp worker_result({:ok, _}), do: :ok
  defp worker_result({:error, :permanent, reason}), do: {:discard, safe_reason(reason)}
  defp worker_result({:error, reason}), do: {:error, safe_reason(reason)}
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, status}) when is_atom(kind) and is_integer(status), do: {kind, status}
  defp safe_reason(_), do: :provider_error
end
