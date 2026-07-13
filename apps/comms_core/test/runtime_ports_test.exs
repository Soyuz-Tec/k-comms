defmodule CommsCore.RuntimePortsTest.ConfiguredDeletionWorker do
end

defmodule CommsCore.RuntimePortsTest.OtherWorker do
end

defmodule CommsCore.RuntimePortsTest do
  use ExUnit.Case, async: false

  alias CommsCore.RuntimePorts

  setup do
    previous_workers = Application.fetch_env!(:comms_core, :job_workers)

    on_exit(fn -> Application.put_env(:comms_core, :job_workers, previous_workers) end)

    {:ok, previous_workers: previous_workers}
  end

  test "resolves and authorizes only the configured worker identity", %{
    previous_workers: previous_workers
  } do
    configured_worker = CommsCore.RuntimePortsTest.ConfiguredDeletionWorker

    Application.put_env(
      :comms_core,
      :job_workers,
      Keyword.put(previous_workers, :deletion, configured_worker)
    )

    assert RuntimePorts.job_worker!(:deletion) == configured_worker

    assert RuntimePorts.job_worker_name!(:deletion) ==
             "CommsCore.RuntimePortsTest.ConfiguredDeletionWorker"

    assert RuntimePorts.authorized_job_worker?(:deletion, configured_worker)
    refute RuntimePorts.authorized_job_worker?(:deletion, CommsCore.RuntimePortsTest.OtherWorker)
  end

  test "fails closed when a worker identity is missing or invalid", %{
    previous_workers: previous_workers
  } do
    Application.put_env(
      :comms_core,
      :job_workers,
      Keyword.delete(previous_workers, :deletion)
    )

    assert_raise KeyError, fn -> RuntimePorts.job_worker!(:deletion) end

    for invalid_worker <- [nil, true, :foo, "not-a-module"] do
      Application.put_env(
        :comms_core,
        :job_workers,
        Keyword.put(previous_workers, :deletion, invalid_worker)
      )

      assert_raise ArgumentError, ~r/invalid :job_workers runtime port :deletion/, fn ->
        RuntimePorts.job_worker!(:deletion)
      end
    end
  end
end
