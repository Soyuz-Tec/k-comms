defmodule CommsTestSupportTest do
  use ExUnit.Case, async: true
  test "generates UUIDs", do: assert({:ok, _} = Ecto.UUID.cast(CommsTestSupport.uuid()))
end
