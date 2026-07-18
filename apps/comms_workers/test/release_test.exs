defmodule CommsWorkers.ReleaseTest do
  use ExUnit.Case, async: false

  alias CommsWorkers.Release

  test "release entrypoint loads and fails closed outside a confirmed one-shot runtime" do
    variable = "K_COMMS_RUNTIME_PURPOSE"
    previous = System.get_env(variable)
    System.delete_env(variable)

    on_exit(fn -> restore_environment(variable, previous) end)

    assert_raise RuntimeError,
                 "attachment restore remap refused: one_shot_runtime_required",
                 fn -> Release.remap_restored_attachment_versions() end
  end

  defp restore_environment(variable, nil), do: System.delete_env(variable)
  defp restore_environment(variable, value), do: System.put_env(variable, value)
end
