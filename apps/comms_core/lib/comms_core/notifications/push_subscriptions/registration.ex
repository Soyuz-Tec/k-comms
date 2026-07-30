defmodule CommsCore.Notifications.PushSubscriptions.Registration do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts
  alias CommsCore.Accounts.AccessGrant
  alias CommsCore.Audit
  alias CommsCore.Notifications.PushSubscription
  alias CommsCore.Notifications.PushSubscriptions.{Ciphertext, Lifecycle, Validation}
  alias CommsCore.Repo
  alias CommsCore.Security.PushSubscriptionBox

  @max_active_subscriptions_per_device 5
  @max_active_subscriptions_per_user 10
  @terminal_statuses [:revoked, :expired, :stale]

  def status do
    encryption = PushSubscriptionBox.status()
    vapid = vapid_status()
    delivery = delivery_status()

    case {encryption, vapid, delivery} do
      {%{status: :available}, %{status: :available}, %{status: status}}
      when status in [:available, :degraded] ->
        %{
          status: :available,
          encryption: encryption,
          vapid: %{status: :available},
          delivery: delivery
        }

      _ ->
        %{
          status: :unavailable,
          reason: unavailable_reason(encryption, vapid, delivery),
          encryption: encryption,
          vapid: Map.drop(vapid, [:public_key]),
          delivery: delivery
        }
    end
  end

  def config(subject) do
    with :ok <- authorize(subject) do
      case {status(), vapid_status()} do
        {%{status: :available}, %{status: :available, public_key: public_key}} ->
          {:ok, %{available: true, vapid_public_key: public_key}}

        _ ->
          {:ok, %{available: false, vapid_public_key: nil}}
      end
    end
  end

  def list(subject) do
    with :ok <- authorize(subject) do
      Lifecycle.expire_due(
        value(subject, :tenant_id),
        value(subject, :user_id),
        value(subject, :device_id)
      )

      {:ok,
       PushSubscription
       |> where(
         [subscription],
         subscription.tenant_id == ^value(subject, :tenant_id) and
           subscription.user_id == ^value(subject, :user_id) and
           subscription.device_id == ^value(subject, :device_id)
       )
       |> order_by([subscription], desc: subscription.inserted_at)
       |> Repo.all()}
    end
  end

  def register(attrs, subject) when is_map(attrs) do
    with :ok <- authorize(subject),
         %{status: :available} <- status(),
         {:ok, normalized} <- Validation.normalize(attrs) do
      Repo.transaction(fn ->
        lock_capacity!(subject)
        lock_endpoint!(normalized.endpoint_hash)
        lock_registration_identity!(subject)

        existing =
          PushSubscription
          |> where([subscription], subscription.endpoint_hash == ^normalized.endpoint_hash)
          |> lock("FOR UPDATE")
          |> Repo.one()

        Lifecycle.expire_due(value(subject, :tenant_id), value(subject, :user_id))

        case existing do
          nil ->
            ensure_capacity!(subject)
            insert_subscription!(normalized, subject)

          %PushSubscription{} = existing ->
            register_existing!(existing, normalized, subject)
        end
      end)
      |> unwrap_transaction()
    else
      %{status: :unavailable, reason: reason} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  def register(_, _), do: {:error, :invalid_push_subscription}

  def revoke(id, subject) when is_binary(id) do
    with :ok <- authorize(subject) do
      Repo.transaction(fn ->
        subscription =
          PushSubscription
          |> where(
            [subscription],
            subscription.id == ^id and subscription.tenant_id == ^value(subject, :tenant_id) and
              subscription.user_id == ^value(subject, :user_id) and
              subscription.device_id == ^value(subject, :device_id)
          )
          |> lock("FOR UPDATE")
          |> Repo.one()

        case subscription do
          nil ->
            Repo.rollback(:not_found)

          %PushSubscription{status: :active} = active ->
            updated = Lifecycle.disable!(active, :revoked, "user_revoked")

            audit!(subject, "push_subscription.revoked", updated.id, %{
              device_id: updated.device_id,
              endpoint_hint: updated.endpoint_hint
            })

            updated

          %PushSubscription{} = terminal ->
            terminal
        end
      end)
      |> unwrap_transaction()
    end
  end

  def revoke(_, _), do: {:error, :not_found}

  defp insert_subscription!(normalized, subject) do
    subscription = %PushSubscription{id: Ecto.UUID.generate()}
    encrypted = Ciphertext.encrypt!(subscription.id, 1, normalized, subject)

    inserted =
      subscription
      |> PushSubscription.changeset(%{
        tenant_id: value(subject, :tenant_id),
        user_id: value(subject, :user_id),
        device_id: value(subject, :device_id),
        endpoint_hash: normalized.endpoint_hash,
        endpoint_hint: normalized.endpoint_hint,
        version: 1,
        ciphertext: encrypted.ciphertext,
        nonce: encrypted.nonce,
        tag: encrypted.tag,
        key_id: encrypted.key_id,
        status: :active,
        expires_at: normalized.expires_at
      })
      |> Repo.insert!()

    audit!(subject, "push_subscription.registered", inserted.id, %{
      device_id: inserted.device_id,
      endpoint_hint: inserted.endpoint_hint
    })

    %{subscription: inserted, replayed: false}
  end

  defp register_existing!(existing, normalized, subject) do
    same_owner? =
      existing.tenant_id == value(subject, :tenant_id) and
        existing.user_id == value(subject, :user_id) and
        existing.device_id == value(subject, :device_id)

    cond do
      not same_owner? ->
        Repo.rollback(:push_subscription_conflict)

      existing.status in @terminal_statuses or expired?(existing) ->
        ensure_capacity!(subject)
        reactivate_subscription!(existing, normalized, subject)

      true ->
        current = Ciphertext.decrypt!(existing)

        if current == normalized.payload do
          %{subscription: existing, replayed: true}
        else
          version = existing.version + 1
          encrypted = Ciphertext.encrypt!(existing.id, version, normalized, subject)

          updated =
            existing
            |> PushSubscription.changeset(%{
              endpoint_hint: normalized.endpoint_hint,
              version: version,
              ciphertext: encrypted.ciphertext,
              nonce: encrypted.nonce,
              tag: encrypted.tag,
              key_id: encrypted.key_id,
              expires_at: normalized.expires_at
            })
            |> Repo.update!()

          audit!(subject, "push_subscription.rotated", updated.id, %{
            device_id: updated.device_id,
            endpoint_hint: updated.endpoint_hint,
            version: version
          })

          %{subscription: updated, replayed: false}
        end
    end
  end

  defp reactivate_subscription!(existing, normalized, subject) do
    version = existing.version + 1
    encrypted = Ciphertext.encrypt!(existing.id, version, normalized, subject)

    updated =
      existing
      |> PushSubscription.changeset(%{
        endpoint_hint: normalized.endpoint_hint,
        version: version,
        ciphertext: encrypted.ciphertext,
        nonce: encrypted.nonce,
        tag: encrypted.tag,
        key_id: encrypted.key_id,
        status: :active,
        expires_at: normalized.expires_at,
        revoked_at: nil,
        stale_at: nil,
        disabled_reason: nil
      })
      |> Repo.update!()

    audit!(subject, "push_subscription.reactivated", updated.id, %{
      device_id: updated.device_id,
      endpoint_hint: updated.endpoint_hint,
      version: version
    })

    %{subscription: updated, replayed: false}
  end

  defp expired?(%PushSubscription{expires_at: nil}), do: false

  defp expired?(%PushSubscription{expires_at: expires_at}),
    do: DateTime.compare(expires_at, now()) != :gt

  defp vapid_status do
    key = Application.get_env(:comms_core, :web_push_vapid_public_key)

    with true <- is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 200,
         true <- Regex.match?(~r/^[A-Za-z0-9_-]+$/, key),
         {:ok, <<4, _::binary-size(64)>>} <- Base.url_decode64(key, padding: false) do
      %{status: :available, public_key: key}
    else
      _ -> %{status: :unavailable, reason: :invalid_web_push_vapid_public_key}
    end
  end

  defp delivery_status do
    case Application.get_env(:comms_core, :push_delivery_status, :unavailable) do
      status when status in [:available, :degraded] -> %{status: status}
      _ -> %{status: :unavailable, reason: :notification_delivery_unavailable}
    end
  end

  defp unavailable_reason(%{status: :unavailable, reason: reason}, _, _), do: reason
  defp unavailable_reason(_, %{status: :unavailable, reason: reason}, _), do: reason
  defp unavailable_reason(_, _, %{status: :unavailable, reason: reason}), do: reason
  defp unavailable_reason(_, _, _), do: :push_subscriptions_unavailable

  defp authorize(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{}} -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp lock_endpoint!(endpoint_hash) do
    lock_key = Base.url_encode64(endpoint_hash, padding: false)

    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      lock_key
    ])
  end

  defp lock_capacity!(subject) do
    lock_key =
      "push-subscription-capacity:#{value(subject, :tenant_id)}:#{value(subject, :user_id)}"

    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      lock_key
    ])
  end

  defp ensure_capacity!(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    device_id = value(subject, :device_id)
    timestamp = now()

    active =
      PushSubscription
      |> where(
        [subscription],
        subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id and
          subscription.status == :active and
          (is_nil(subscription.expires_at) or subscription.expires_at > ^timestamp)
      )

    user_count = Repo.aggregate(active, :count)

    device_count =
      active
      |> where([subscription], subscription.device_id == ^device_id)
      |> Repo.aggregate(:count)

    if user_count >= @max_active_subscriptions_per_user or
         device_count >= @max_active_subscriptions_per_device do
      Repo.rollback(:push_subscription_limit_reached)
    end
  end

  defp lock_registration_identity!(subject) do
    case Accounts.lock_push_registration_identity(
           value(subject, :tenant_id),
           value(subject, :user_id),
           value(subject, :device_id)
         ) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit!(subject, action, resource_id, metadata) do
    Audit.record(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: "push_subscription",
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
