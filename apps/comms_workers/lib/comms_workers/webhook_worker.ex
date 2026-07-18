defmodule CommsWorkers.WebhookWorker do
  use Oban.Worker, queue: :webhooks, max_attempts: 12

  alias CommsCore.Integrations
  alias CommsCore.Integrations.WebhookDeliveryClaim
  alias CommsIntegrations.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    case Integrations.claim_delivery(delivery_id) do
      {:ok, :already_delivered} ->
        :ok

      {:ok, %WebhookDeliveryClaim{} = claim} ->
        with {:ok, request} <- Integrations.delivery_request(claim) do
          result = Webhooks.deliver(request)

          case Integrations.record_delivery(claim, result) do
            {:ok, :recorded} -> worker_result(result)
            {:error, :stale_delivery_claim} -> :ok
            {:error, reason} -> {:error, safe_reason(reason)}
          end
        else
          {:error, reason} -> record_internal_failure(claim, reason)
        end

      {:error, :not_found} ->
        {:discard, :delivery_not_found}

      {:error, :endpoint_disabled} ->
        {:discard, :endpoint_disabled}

      {:error, :terminal_delivery} ->
        {:discard, :terminal_delivery}

      {:error, :not_claimable} ->
        {:snooze, 30}

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_), do: {:discard, :delivery_id_required}

  defp record_internal_failure(delivery, reason) do
    result = internal_failure_result(reason)

    case Integrations.record_delivery(delivery, result) do
      {:ok, _updated} -> worker_result(result)
      {:error, :stale_delivery_claim} -> :ok
      {:error, record_reason} -> {:error, safe_reason(record_reason)}
    end
  end

  @doc false
  def internal_failure_result(:legacy_secret_requires_rotation),
    do: {:error, :permanent, :legacy_secret_requires_rotation}

  def internal_failure_result(reason), do: {:error, safe_reason(reason)}

  @doc false
  def worker_result(:ok), do: :ok
  def worker_result({:ok, _}), do: :ok
  def worker_result({:error, :permanent, reason}), do: {:discard, safe_reason(reason)}
  def worker_result({:error, reason}), do: {:error, safe_reason(reason)}
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, status}) when is_atom(kind) and is_integer(status), do: {kind, status}
  defp safe_reason(_), do: :provider_error
end
