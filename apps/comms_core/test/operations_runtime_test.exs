defmodule CommsCore.OperationsRuntimeTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Operations

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
             attachment_scan_failures: attachment_scan_failures
           } = Operations.runtime_gauges()

    assert is_number(queue_age_seconds)

    for count <- [
          jobs_pending,
          jobs_discarded,
          outbox_pending,
          attachments_quarantined,
          notification_failures,
          webhook_failures,
          attachment_scan_failures
        ] do
      assert is_integer(count)
      assert count >= 0
    end
  end
end
