defmodule CommsCore.Telephony.CallMonitor do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Repo, RuntimePorts}
  alias CommsCore.Telephony.Call

  @doc false
  @spec enqueue_bound_call_monitor!(%Call{}) :: Oban.Job.t()
  def enqueue_bound_call_monitor!(%Call{} = call),
    do: enqueue!(call.id, DateTime.add(now(), 5, :second))

  @doc false
  @spec enqueue_capture_monitor!(%Call{}, DateTime.t()) :: %Call{}
  def enqueue_capture_monitor!(%Call{} = call, %DateTime{} = deadline) do
    if not Repo.in_transaction?(), do: Repo.rollback(:transaction_required)

    current =
      Repo.one(
        from(c in Call,
          where: c.id == ^call.id and c.tenant_id == ^call.tenant_id,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(current), do: Repo.rollback(:not_found)

    if current.status in [:ringing, :answered] do
      expires_at =
        if DateTime.compare(current.expires_at, deadline) == :lt,
          do: current.expires_at,
          else: deadline

      current = current |> Call.changeset(%{expires_at: expires_at}) |> Repo.update!()
      enqueue_bound_call_monitor!(current)
      enqueue!(current.id, current.expires_at)
      current
    else
      current
    end
  end

  defp enqueue!(id, scheduled_at) do
    %{"call_id" => id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:telephony_expiry),
      queue: :lifecycle,
      max_attempts: 100,
      scheduled_at: scheduled_at
    )
    |> Oban.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
