defmodule CommsObservability do
  @moduledoc "Shared K-Comms telemetry event prefix."

  def execute(event, measurements, metadata \\ %{}) do
    CommsObservability.Metrics.record(event, measurements)
    :telemetry.execute([:k_comms | event], measurements, metadata)
  end
end
