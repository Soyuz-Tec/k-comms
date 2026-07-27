defmodule CommsCore.PasswordTest do
  use ExUnit.Case, async: true

  alias CommsCore.Security.Password

  test "hashes and verifies passwords" do
    hash = Password.hash("a-long-and-valid-password")
    assert Password.verify("a-long-and-valid-password", hash)
    refute Password.verify("wrong-password", hash)
    refute hash =~ "a-long-and-valid-password"
    assert String.starts_with?(hash, "pbkdf2-sha256$600000$")
    refute Password.needs_rehash?(hash)
  end

  test "accepts legacy hashes for upgrade and keeps all authentication paths at the current cost" do
    password = "a-long-and-valid-password"
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, password, salt, 210_000, 32)

    legacy_hash =
      Enum.join(
        [
          "pbkdf2-sha256",
          "210000",
          Base.url_encode64(salt, padding: false),
          Base.url_encode64(digest, padding: false)
        ],
        "$"
      )

    assert Password.verify(password, legacy_hash)
    refute Password.verify("wrong-password", legacy_hash)
    assert Password.needs_rehash?(legacy_hash)
    refute Password.verify(password, nil)
    refute Password.verify(password, "pbkdf2-sha256$1000001$invalid$invalid")
  end
end
