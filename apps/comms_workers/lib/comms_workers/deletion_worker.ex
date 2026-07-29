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

      # Variants are separate objects under the same attachment. Erasure is only
      # complete when they go too, so a failure halts the request rather than
      # leaving a derived preview of erased content behind.
      with :ok <- delete_variants(attachment),
           :ok <- ObjectStorage.delete_object(request) do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_variants(%{tenant_id: tenant_id, variants: variants}) when is_list(variants) do
    Enum.reduce_while(variants, :ok, fn variant, :ok ->
      case delete_variant(tenant_id, variant) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_variants(_attachment), do: :ok

  defp delete_variant(tenant_id, %{object_key: key, object_version_id: version})
       when is_binary(key) and is_binary(version) do
    ObjectStorage.delete_object(%{
      tenant_id: tenant_id,
      object_key: key,
      object_version_id: version
    })
  end

  # A declared but never-verified variant has no object version to remove. The
  # abandonment purge sweeps its key instead.
  defp delete_variant(_tenant_id, _variant), do: :ok

  defp record_failure(request_id, reason) do
    _ = Governance.record_deletion_failure(request_id, reason, __MODULE__)
    {:error, safe_reason(reason)}
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, status}) when is_atom(kind) and is_integer(status), do: {kind, status}
  defp safe_reason(_reason), do: :deletion_failed
end
