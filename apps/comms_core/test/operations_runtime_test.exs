defmodule CommsCore.OperationsRuntimeTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Operations, Repo}

  test "database readiness returns bounded content-free health evidence" do
    assert {:ok, latency_ms} = Operations.database_readiness()
    assert is_float(latency_ms)
    assert latency_ms >= 0
  end

  test "runtime gauges expose the fixed operational aggregate shape" do
    assert %{
             queue_age_seconds: queue_age_seconds,
             jobs_pending: jobs_pending,
             jobs_discarded: jobs_discarded,
             outbox_pending: outbox_pending,
             attachments_quarantined: attachments_quarantined,
             notification_failures: notification_failures,
             webhook_failures: webhook_failures,
             attachment_scan_failures: attachment_scan_failures,
             attachment_cleanup_failures: attachment_cleanup_failures
           } = Operations.runtime_gauges()

    assert is_number(queue_age_seconds)

    for count <- [
          jobs_pending,
          jobs_discarded,
          outbox_pending,
          attachments_quarantined,
          notification_failures,
          webhook_failures,
          attachment_scan_failures,
          attachment_cleanup_failures
        ] do
      assert is_integer(count)
      assert count >= 0
    end
  end

  test "queue age includes only runnable pending work" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_job("completed", DateTime.add(now, -10_800, :second))
    insert_job("scheduled", DateTime.add(now, 10_800, :second))

    assert %{queue_age_seconds: age_without_runnable_work} =
             Operations.runtime_gauges()

    assert age_without_runnable_work >= 0
    assert age_without_runnable_work < 5

    insert_job("available", DateTime.add(now, -120, :second))

    assert %{queue_age_seconds: runnable_age} = Operations.runtime_gauges()
    assert runnable_age >= 115
    assert runnable_age < 180
  end

  defp insert_job(state, scheduled_at) do
    %Oban.Job{}
    |> Ecto.Changeset.change(%{
      state: state,
      queue: "default",
      worker: "CommsWorkers.OutboxWorker",
      args: %{"probe" => Ecto.UUID.generate()},
      meta: %{},
      tags: [],
      errors: [],
      attempt: 0,
      max_attempts: 20,
      priority: 0,
      inserted_at: scheduled_at,
      scheduled_at: scheduled_at
    })
    |> Repo.insert!()
  end
end
