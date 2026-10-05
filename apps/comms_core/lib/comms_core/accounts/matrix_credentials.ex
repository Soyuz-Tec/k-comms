defmodule CommsCore.Accounts.MatrixCredentials do
  @moduledoc false
  alias CommsCore.Accounts.IdentitySecretBox

  def seal(value, record) when is_map(value) do
    with {:ok, encrypted} <- IdentitySecretBox.encrypt(Jason.encode!(value), context(record)) do
      {:ok,
       Map.new(encrypted, fn {key, bytes} -> {Atom.to_string(key), Base.encode64(bytes)} end)}
    end
  end

  def open(envelope, record) when is_map(envelope) do
    with {:ok, ciphertext} <- decode(envelope, "ciphertext"),
         {:ok, nonce} <- decode(envelope, "nonce"),
         {:ok, tag} <- decode(envelope, "tag"),
         {:ok, key_id} <- decode(envelope, "key_id"),
         {:ok, plaintext} <-
           IdentitySecretBox.decrypt(
             %{ciphertext: ciphertext, nonce: nonce, tag: tag, key_id: key_id},
             context(record)
           ),
         {:ok, value} when is_map(value) <- Jason.decode(plaintext) do
      {:ok, value}
    else
      _ -> {:error, :matrix_credential_unavailable}
    end
  end

  def open(_, _), do: {:error, :matrix_credential_unavailable}
  defp decode(map, key), do: Base.decode64(Map.get(map, key, ""))

  defp context(record),
    do: %{tenant_id: record.tenant_id, identity_secret_id: record.id, version: record.generation}
end
