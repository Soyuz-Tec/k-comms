defmodule CommsCore.Security.Password do
  @moduledoc "PBKDF2-SHA256 password hashing without a native dependency."

  @algorithm "pbkdf2-sha256"
  @iterations 600_000
  @minimum_legacy_iterations 100_000
  @maximum_supported_iterations 1_000_000
  @bytes 32
  @dummy_salt <<0::128>>

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
    with {:ok, iterations, salt, expected} <- parse(encoded) do
      actual = derive(password, salt, iterations)
      byte_size(actual) == byte_size(expected) and :crypto.hash_equals(actual, expected)
    else
      _ ->
        dummy_verify(password)
        false
    end
  end

  # Unknown identities still pay the current password-verification cost so the
  # login endpoint does not expose account existence through a quick exit.
  def verify(password, nil) when is_binary(password) do
    dummy_verify(password)
    false
  end

  def verify(_, _), do: false

  def needs_rehash?(encoded) when is_binary(encoded) do
    case parse(encoded) do
      {:ok, iterations, _salt, _expected} -> iterations < @iterations
      _ -> true
    end
  end

  def needs_rehash?(_), do: true

  @doc false
  def current_iterations, do: @iterations

  def valid_password?(password) when is_binary(password) do
    String.length(password) >= 12 and String.length(password) <= 256
  end

  def valid_password?(_), do: false

  defp parse(encoded) do
    with [@algorithm, iteration_text, salt_text, digest_text] <- String.split(encoded, "$"),
         {iterations, ""} <- Integer.parse(iteration_text),
         {:ok, salt} <- Base.url_decode64(salt_text, padding: false),
         {:ok, expected} <- Base.url_decode64(digest_text, padding: false),
         true <-
           iterations >= @minimum_legacy_iterations and
             iterations <= @maximum_supported_iterations,
         true <- byte_size(salt) == 16 and byte_size(expected) == @bytes do
      {:ok, iterations, salt, expected}
    else
      _ -> {:error, :invalid_password_hash}
    end
  end

  defp derive(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @bytes)
  end

  defp dummy_verify(password) do
    derive(password, @dummy_salt, @iterations)
    :ok
  end
end
