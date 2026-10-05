defmodule CommsCore.AudioCalls.CalendarSync.Boxes do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.{SecretBox, SecretContext}
  alias CommsCore.Repo

  def encrypt!(value, %SecretContext{} = context) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, box} <- SecretBox.encrypt(encoded, context) do
      %{
        "key_id" => box.key_id,
        "ciphertext" => Base.encode64(box.ciphertext),
        "nonce" => Base.encode64(box.nonce),
        "tag" => Base.encode64(box.tag)
      }
    else
      _ -> Repo.rollback(:calendar_secret_unavailable)
    end
  end

  def decrypt!(%{"key_id" => id, "ciphertext" => cipher, "nonce" => nonce, "tag" => tag}, context)
      when is_binary(id) and is_binary(cipher) and is_binary(nonce) and is_binary(tag) do
    with {:ok, cipher} <- Base.decode64(cipher),
         {:ok, nonce} <- Base.decode64(nonce),
         {:ok, tag} <- Base.decode64(tag),
         {:ok, plaintext} <-
           SecretBox.decrypt(%{key_id: id, ciphertext: cipher, nonce: nonce, tag: tag}, context),
         {:ok, value} when is_map(value) <- Jason.decode(plaintext) do
      value
    else
      _ -> Repo.rollback(:calendar_secret_unavailable)
    end
  end

  def decrypt!(_, _), do: Repo.rollback(:calendar_secret_unavailable)
end
