defmodule CommsWorkers.AttachmentAbandonWorker do
  @moduledoc """
  Purges every object version below an abandoned attachment's unique key.

  The core owns the durable lifecycle and refuses work before the persisted
  upload authorization has expired plus its settling grace. Storage success is
  recorded only after the adapter verifies that no versions or delete markers
  remain.
  """

  use Oban.Worker, queue: :media, max_attempts: 20

  alias CommsCore.Attachments
  alias CommsIntegrations.ObjectStorage

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{"attachment_id" => attachment_id, "tenant_id" => tenant_id}
        } = job
      ) do
    case Attachments.claim_abandon_cleanup(tenant_id, attachment_id, __MODULE__) do
      {:ok, %{id: _, tenant_id: _, object_key: _} = target} ->
        purge(job, target)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, :not_found} ->
        {:discard, :attachment_not_found}

      {:error, :not_abandoned} ->
        {:discard, :attachment_not_abandoned}

      {:error, :cleanup_complete} ->
        :ok

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :tenant_and_attachment_id_required}

  defp purge(job, target) do
    request = %{tenant_id: target.tenant_id, object_key: target.object_key}

    case ObjectStorage.purge_object_versions(request) do
      {:ok, %{verified_empty?: true}} ->
        case Attachments.complete_abandon_cleanup(target.tenant_id, target.id, __MODULE__) do
          {:ok, _attachment} -> :ok
          {:error, reason} -> {:error, safe_reason(reason)}
        end

      {:ok, %{verified_empty?: false}} ->
        fail(job, target, :object_versions_remain)

      :ok ->
        fail(job, target, :object_cleanup_not_verified)

      {:error, reason} ->
        fail(job, target, reason)

      _other ->
        fail(job, target, :object_cleanup_invalid_response)
    end
  rescue
    _error -> fail(job, target, :object_storage_unavailable)
  end

  defp fail(job, target, reason) do
    terminal? = final_attempt?(job)

    case Attachments.record_abandon_cleanup_failure(
           target.tenant_id,
           target.id,
           reason,
           terminal?,
           __MODULE__
         ) do
      {:ok, _attachment} -> {:error, safe_reason(reason)}
      {:error, state_reason} -> {:error, safe_reason(state_reason)}
    end
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts

  defp final_attempt?(_job), do: false

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, status}) when is_atom(kind) and is_integer(status), do: {kind, status}
  defp safe_reason(_reason), do: :attachment_abandon_cleanup_failed
end
