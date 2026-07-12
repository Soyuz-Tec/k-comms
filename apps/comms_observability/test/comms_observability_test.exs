defmodule CommsObservabilityTest do
  use ExUnit.Case, async: true
  test "module loads", do: assert(Code.ensure_loaded?(CommsObservability))
end
