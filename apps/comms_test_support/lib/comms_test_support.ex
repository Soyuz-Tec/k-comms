defmodule CommsTestSupport do
  @moduledoc "Shared deterministic helpers for cross-application tests."
  def uuid, do: Ecto.UUID.generate()
end
