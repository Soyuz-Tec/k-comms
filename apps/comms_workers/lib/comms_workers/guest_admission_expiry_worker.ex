defmodule CommsWorkers.GuestAdmissionExpiryWorker do
  use Oban.Worker, queue: :default, max_attempts: 20

  alias CommsCore.Conversations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"admission_id" => admission_id}})
      when is_binary(admission_id) do
    case Conversations.expire_guest_admission(admission_id, __MODULE__) do
      {:ok, :expired} -> :ok
      {:ok, :already_terminal} -> :ok
      {:ok, {:not_due, seconds}} -> {:snooze, max(seconds, 1)}
      {:error, :guest_admission_not_found} -> {:discard, :guest_admission_not_found}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :admission_id_required}

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :guest_admission_expiry_failed
end
