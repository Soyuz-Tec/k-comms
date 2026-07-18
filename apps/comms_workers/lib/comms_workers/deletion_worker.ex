defmodule CommsWorkers.DeletionWorker do
  use Oban.Worker, queue: :default, max_attempts: 10

  alias CommsCore.Governance
  alias CommsCore.Governance.DeletionExecution
  alias CommsIntegrations.ObjectStorage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deletion_request_id" => request_id}}) do
    case Governance.claim_deletion_request(request_id, __MODULE__) do
      {:ok, %DeletionExecution{} = execution} -> execute_claim(execution)
      {:error, :legal_hold_active} -> {:snooze, 300}
      {:error, :not_claimable} -> {:discard, :not_claimable}
      {:error, :not_found} -> {:discard, :not_found}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :deletion_request_id_required}

  defp execute_claim(%DeletionExecution{} = execution) do
    case delete_objects(execution.objects) do
      {:ok, deleted_count} ->
        case Governance.complete_deletion_request(
               execution.request_id,
               execution.expected_version,
               %{deleted_object_count: deleted_count},
               __MODULE__
             ) do
          {:ok, _result} -> :ok
          {:error, :already_delivered} -> :ok
          {:error, :legal_hold_active} -> {:snooze, 300}
          {:error, reason} -> record_failure(execution.request_id, reason)
        end

      {:error, reason} ->
        record_failure(execution.request_id, reason)
    end
  end

  defp delete_objects(attachments) do
    Enum.reduce_while(attachments, {:ok, 0}, fn attachment, {:ok, count} ->
      request = %{
        tenant_id: attachment.tenant_id,
        object_key: attachment.object_key,
        object_version_id: attachment.object_version_id
      }

      case ObjectStorage.delete_object(request) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_failure(request_id, reason) do
    _ = Governance.record_deletion_failure(request_id, reason, __MODULE__)
    {:error, safe_reason(reason)}
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, status}) when is_atom(kind) and is_integer(status), do: {kind, status}
  defp safe_reason(_reason), do: :deletion_failed
end
