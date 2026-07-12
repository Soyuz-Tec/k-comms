defmodule CommsCore.Security.Password do
  @moduledoc "PBKDF2-SHA256 password hashing without a native dependency."

  @algorithm "pbkdf2-sha256"
  @iterations 210_000
  @bytes 32

  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(16)
    digest = derive(password, salt, @iterations)

    Enum.join(
      [
        @algorithm,
        Integer.to_string(@iterations),
        Base.url_encode64(salt, padding: false),
        Base.url_encode64(digest, padding: false)
      ],
      "$"
    )
  end

  def verify(password, encoded) when is_binary(password) and is_binary(encoded) do
    with [@algorithm, iteration_text, salt_text, digest_text] <- String.split(encoded, "$"),
         {iterations, ""} <- Integer.parse(iteration_text),
         {:ok, salt} <- Base.url_decode64(salt_text, padding: false),
         {:ok, expected} <- Base.url_decode64(digest_text, padding: false),
         true <- iterations >= 100_000 and iterations <= 1_000_000 do
      actual = derive(password, salt, iterations)
      byte_size(actual) == byte_size(expected) and :crypto.hash_equals(actual, expected)
    else
      _ -> false
    end
  end

  def verify(_, _), do: false

  def valid_password?(password) when is_binary(password) do
    String.length(password) >= 12 and String.length(password) <= 256
  end

  def valid_password?(_), do: false

  defp derive(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @bytes)
  end
end
