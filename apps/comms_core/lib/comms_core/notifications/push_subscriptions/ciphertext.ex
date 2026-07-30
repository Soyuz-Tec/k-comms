defmodule CommsCore.Notifications.PushSubscriptions.Ciphertext do
  @moduledoc false

  alias CommsCore.Notifications.PushSubscriptions.Validation
  alias CommsCore.Repo
  alias CommsCore.Security.PushSubscriptionBox

  def encrypt!(subscription_id, version, normalized, subject) do
    normalized.json
    |> PushSubscriptionBox.encrypt(%{
      tenant_id: value(subject, :tenant_id),
      subscription_id: subscription_id,
      version: version
    })
    |> unwrap_or_rollback()
  end

  def decrypt!(subscription) do
    encrypted = %{
      ciphertext: subscription.ciphertext,
      nonce: subscription.nonce,
      tag: subscription.tag,
      key_id: subscription.key_id
    }

    with {:ok, plaintext} <-
           PushSubscriptionBox.decrypt(encrypted, %{
             tenant_id: subscription.tenant_id,
             subscription_id: subscription.id,
             version: subscription.version
           }),
         {:ok, decoded} <- Jason.decode(plaintext),
         true <- Validation.valid_materialized?(decoded) do
      decoded
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:invalid_encrypted_push_subscription)
    end
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
