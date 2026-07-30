defmodule CommsCore.Integrations.WebhookSecrets do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Integrations.{WebhookDelivery, WebhookEndpoint, WebhookSecret}
  alias CommsCore.Repo
  alias CommsCore.Security.SecretBox

  def status, do: SecretBox.status()

  def generate, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  def encrypt!(secret, value, version) do
    case SecretBox.encrypt(secret, secret_context(value, version)) do
      {:ok, encrypted} -> encrypted
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def insert!(%WebhookEndpoint{} = endpoint, version, encrypted) do
    %WebhookSecret{}
    |> WebhookSecret.changeset(%{
      tenant_id: endpoint.tenant_id,
      endpoint_id: endpoint.id,
      version: version,
      ciphertext: encrypted.ciphertext,
      nonce: encrypted.nonce,
      tag: encrypted.tag,
      key_id: encrypted.key_id
    })
    |> Repo.insert!()
  end

  def retire_current!(%WebhookEndpoint{} = endpoint) do
    from(existing in WebhookSecret,
      where:
        existing.endpoint_id == ^endpoint.id and existing.version == ^endpoint.secret_version and
          is_nil(existing.retired_at)
    )
    |> Repo.update_all(set: [retired_at: now()])
  end

  def materialize!(%WebhookDelivery{} = delivery, %WebhookEndpoint{} = endpoint) do
    if delivery.secret_version != endpoint.secret_version do
      Repo.rollback(:webhook_secret_unavailable)
    end

    secret =
      Repo.one(
        from(secret in WebhookSecret,
          where:
            secret.tenant_id == ^delivery.tenant_id and
              secret.endpoint_id == ^delivery.endpoint_id and
              secret.version == ^delivery.secret_version and is_nil(secret.retired_at)
        )
      ) || Repo.rollback(:webhook_secret_unavailable)

    case SecretBox.decrypt(
           %{
             ciphertext: secret.ciphertext,
             nonce: secret.nonce,
             tag: secret.tag,
             key_id: secret.key_id
           },
           secret_context(delivery, delivery.secret_version)
         ) do
      {:ok, plaintext} -> plaintext
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp secret_context(value, version) do
    %{
      tenant_id: value(value, :tenant_id),
      endpoint_id: value(value, :endpoint_id) || value(value, :id),
      version: version
    }
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
