defmodule CommsWorkers.WebhookWorkerTest do
  use ExUnit.Case, async: true

  alias CommsWorkers.WebhookWorker

  test "legacy webhook secrets are terminal while transport failures remain retryable" do
    assert {:error, :permanent, :legacy_secret_requires_rotation} =
             WebhookWorker.internal_failure_result(:legacy_secret_requires_rotation)

    assert {:error, :outbound_timeout} =
             WebhookWorker.internal_failure_result(:outbound_timeout)
  end

  test "provider transport failures retry while protocol failures discard" do
    for reason <- [
          :outbound_dns_unavailable,
          :outbound_timeout,
          :outbound_transport_error,
          :outbound_tls_error,
          {:webhook_status, 503}
        ] do
      assert {:error, ^reason} = WebhookWorker.worker_result({:error, reason})
    end

    for reason <- [
          :outbound_response_too_large,
          :outbound_response_headers_too_large,
          :outbound_invalid_response
        ] do
      assert {:discard, ^reason} =
               WebhookWorker.worker_result({:error, :permanent, reason})
    end
  end
end
