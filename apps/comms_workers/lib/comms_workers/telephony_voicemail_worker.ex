defmodule CommsWorkers.TelephonyVoicemailWorker do
  @moduledoc "Durable PBX-to-approved-storage reconciliation and protected voicemail erasure."
  use Oban.Worker, queue: :lifecycle, max_attempts: 100
  alias CommsCore.Telephony
  alias CommsCore.Telephony.{VoicemailProviderPort, VoicemailRequest}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"voicemail_id" => id}}) when is_binary(id) do
    case Telephony.claim_voicemail(id, __MODULE__) do
      {:ok, %VoicemailRequest{operation: :reconcile} = request} ->
        with {:ok, media} <- VoicemailProviderPort.fetch(request),
             {:ok, _} <- Telephony.store_voicemail(id, media, __MODULE__) do
          cleanup_source(id)
        else
          {:error, :not_found} ->
            case Telephony.complete_voicemail(id, {:error, :not_found}, __MODULE__) do
              {:ok, :deleting} -> {:snooze, 1}
              {:ok, :pending} -> {:snooze, 3}
              {:error, _} -> {:error, :voicemail_reconciliation_failed}
            end

          {:error, _} ->
            {:error, :voicemail_reconciliation_failed}
        end

      {:ok, %VoicemailRequest{operation: :delete_source}} ->
        cleanup_source(id)

      {:ok, %VoicemailRequest{operation: :delete}} ->
        case Telephony.purge_voicemail(id, __MODULE__) do
          {:ok, :held} -> {:snooze, 86_400}
          {:ok, :deleted} -> :ok
          {:error, _} -> {:error, :voicemail_deletion_failed}
        end

      {:ok, :held} ->
        {:snooze, 86_400}

      {:ok, :complete} ->
        :ok

      {:error, :not_found} ->
        {:discard, :voicemail_not_found}

      {:error, _} ->
        {:error, :voicemail_claim_failed}
    end
  end

  def perform(_), do: {:discard, :voicemail_id_required}

  defp cleanup_source(id) do
    case Telephony.cleanup_voicemail_source(id, __MODULE__) do
      {:ok, :held} -> {:snooze, 86_400}
      {:ok, :complete} -> :ok
      {:error, _} -> {:error, :voicemail_source_cleanup_failed}
    end
  end
end
