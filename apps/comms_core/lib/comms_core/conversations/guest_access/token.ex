defmodule CommsCore.Conversations.GuestAccess.Token do
  @moduledoc false

  import Bitwise

  @verification_secret_bytes 32

  def parse(token) do
    with [link_id, encoded_secret] <- String.split(token, ".", parts: 2),
         {:ok, link_id} <- Ecto.UUID.cast(link_id),
         {:ok, secret} <- Base.url_decode64(encoded_secret, padding: false),
         32 <- byte_size(secret) do
      {:ok, link_id, secret}
    else
      _ -> {:error, :guest_link_unavailable}
    end
  end

  def secure_digest_match?(secret, stored_digest)
      when is_binary(secret) and is_binary(stored_digest) do
    secure_binary_match?(:crypto.hash(:sha256, secret), stored_digest)
  end

  def secure_digest_match?(_secret, _stored_digest), do: false

  def secure_binary_match?(candidate, stored)
      when is_binary(candidate) and is_binary(stored) do
    if byte_size(candidate) == byte_size(stored) do
      candidate
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(stored))
      |> Enum.reduce(0, fn {left, right}, difference ->
        bor(difference, bxor(left, right))
      end)
      |> Kernel.==(0)
    else
      false
    end
  end

  def secure_binary_match?(_candidate, _stored), do: false

  def conversion_verification_credentials(
        nil,
        _link_secret,
        _tenant_id,
        _conversation_id,
        _link_id
      ),
      do: {nil, nil}

  def conversion_verification_credentials(
        conversion_email,
        link_secret,
        tenant_id,
        conversation_id,
        link_id
      ) do
    secret = independent_secret(link_secret)

    {
      Base.url_encode64(secret, padding: false),
      conversion_verification_digest(
        secret,
        tenant_id,
        conversation_id,
        link_id,
        conversion_email
      )
    }
  end

  def conversion_verification_secret(code) when is_binary(code) do
    with true <- byte_size(code) == 43,
         {:ok, secret} <- Base.url_decode64(code, padding: false),
         true <- byte_size(secret) == @verification_secret_bytes do
      {true, secret}
    else
      _ -> {false, <<0::size(@verification_secret_bytes * 8)>>}
    end
  end

  def conversion_verification_secret(_code),
    do: {false, <<0::size(@verification_secret_bytes * 8)>>}

  def conversion_verification_digest(
        secret,
        tenant_id,
        conversation_id,
        link_id,
        conversion_email
      ) do
    :crypto.hash(:sha256, [
      "k-comms:guest-conversion-verification:v1",
      <<0>>,
      tenant_id,
      <<0>>,
      conversation_id,
      <<0>>,
      link_id,
      <<0>>,
      conversion_email,
      <<0>>,
      secret
    ])
  end

  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_email), do: ""

  def email_hint(nil), do: nil

  def email_hint(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        String.first(local) <> "***@" <> domain

      _ ->
        nil
    end
  end

  def valid_conversion_email?(email) do
    String.length(email) <= 320 and
      Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, email) and
      not String.ends_with?(email, "@service.invalid")
  end

  defp independent_secret(excluded_secret) do
    secret = :crypto.strong_rand_bytes(@verification_secret_bytes)

    if secret == excluded_secret,
      do: independent_secret(excluded_secret),
      else: secret
  end
end
