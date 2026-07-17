defmodule CommsCore.Governance.DeletionExecution do
  @moduledoc "Stable, capability-limited deletion work claimed by the deletion adapter."

  @derive {Inspect, only: [:request_id, :expected_version]}
  @enforce_keys [:request_id, :expected_version, :objects]
  defstruct [:request_id, :expected_version, :objects]
end
