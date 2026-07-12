defmodule CommsWorkers.WorkerTest do
  use ExUnit.Case, async: true
  test "attachment worker fails closed", do: assert {:discard, _} = CommsWorkers.AttachmentWorker.perform(%Oban.Job{args: %{}})
end
