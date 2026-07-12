defmodule CommsCore.PasswordTest do
  use ExUnit.Case, async: true

  alias CommsCore.Security.Password

  test "hashes and verifies passwords" do
    hash = Password.hash("a-long-and-valid-password")
    assert Password.verify("a-long-and-valid-password", hash)
    refute Password.verify("wrong-password", hash)
    refute hash =~ "a-long-and-valid-password"
  end
end
