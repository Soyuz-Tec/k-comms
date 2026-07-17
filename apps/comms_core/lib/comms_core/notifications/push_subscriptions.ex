defmodule CommsCore.Notifications.PushSubscriptions do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{AccessGrant, Device, User}
  alias CommsCore.Audit
  alias CommsCore.Notifications.PushSubscription
  alias CommsCore.Repo
  alias CommsCore.Security.PushSubscriptionBox

  @subscription_format_version 1
  @max_endpoint_bytes 2_048
  @max_expiration_seconds 10 * 365 * 24 * 60 * 60
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
      expire_due(value(subject, :tenant_id), value(subject, :user_id), value(subject, :device_id))

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
         {:ok, normalized} <- normalize_subscription(attrs) do
      Repo.transaction(fn ->
        lock_capacity!(subject)
        lock_endpoint!(normalized.endpoint_hash)
        ensure_active_identity!(subject)
        expire_due(value(subject, :tenant_id), value(subject, :user_id), nil)

        case Repo.get_by(PushSubscription, endpoint_hash: normalized.endpoint_hash) do
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
            updated = disable!(active, :revoked, "user_revoked")

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

  def active_subscription_ids(tenant_id, user_id)
      when is_binary(tenant_id) and is_binary(user_id) do
    expire_due(tenant_id, user_id, nil)

    PushSubscription
    |> join(:inner, [subscription], user in User,
      on:
        user.tenant_id == subscription.tenant_id and user.id == subscription.user_id and
          user.status == :active and user.account_type == :human
    )
    |> join(:inner, [subscription, _user], device in Device,
      on:
        device.tenant_id == subscription.tenant_id and device.user_id == subscription.user_id and
          device.id == subscription.device_id and is_nil(device.revoked_at)
    )
    |> where(
      [subscription, _user, _device],
      subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id and
        subscription.status == :active and
        (is_nil(subscription.expires_at) or subscription.expires_at > ^now())
    )
    |> order_by([subscription, _user, _device], asc: subscription.id)
    |> limit(^@max_active_subscriptions_per_user)
    |> select([subscription, _user, _device], %{
      id: subscription.id,
      version: subscription.version
    })
    |> Repo.all()
  end

  def materialize_destination(subscription_id, version, tenant_id)
      when is_binary(subscription_id) and is_integer(version) and version > 0 and
             is_binary(tenant_id) do
    Repo.transaction(fn ->
      subscription =
        PushSubscription
        |> join(:inner, [subscription], user in User,
          on:
            user.tenant_id == subscription.tenant_id and user.id == subscription.user_id and
              user.status == :active and user.account_type == :human
        )
        |> join(:inner, [subscription, _user], device in Device,
          on:
            device.tenant_id == subscription.tenant_id and
              device.user_id == subscription.user_id and device.id == subscription.device_id and
              is_nil(device.revoked_at)
        )
        |> where(
          [subscription, _user, _device],
          subscription.id == ^subscription_id and subscription.tenant_id == ^tenant_id and
            subscription.version == ^version
        )
        |> select([subscription, _user, _device], subscription)
        |> Repo.one()

      case subscription do
        nil ->
          Repo.rollback(:push_subscription_stale)

        %PushSubscription{status: status} when status in @terminal_statuses ->
          Repo.rollback(terminal_error(status))

        %PushSubscription{} = active ->
          if expired?(active) do
            _ = disable!(active, :expired, "subscription_expired")
            Repo.rollback(:push_subscription_expired)
          else
            destination = decrypt_subscription!(active)

            case PushSubscription
                 |> where(
                   [subscription],
                   subscription.id == ^active.id and subscription.version == ^version and
                     subscription.status == :active
                 )
                 |> Repo.update_all(set: [last_materialized_at: now(), updated_at: now()]) do
              {1, _} -> :ok
              _ -> Repo.rollback(:push_subscription_stale)
            end

            unless delivery_eligible?(active.id, version, tenant_id),
              do: Repo.rollback(:push_subscription_stale)

            destination
          end
      end
    end)
    |> unwrap_transaction()
  end

  def materialize_destination(_, _, _), do: {:error, :push_subscription_stale}

  def record_provider_result(
        subscription_id,
        version,
        {:error, :permanent, {:notification_status, status}}
      )
      when is_binary(subscription_id) and is_integer(version) and status in [404, 410] do
    timestamp = now()

    PushSubscription
    |> where(
      [subscription],
      subscription.id == ^subscription_id and subscription.version == ^version and
        subscription.status == :active
    )
    |> Repo.update_all(
      set: [
        status: :stale,
        stale_at: timestamp,
        disabled_reason: "provider_endpoint_gone",
        updated_at: timestamp
      ]
    )

    :ok
  end

  def record_provider_result(_subscription_id, _version, _result), do: :ok

  def disable_for_device(tenant_id, user_id, device_id, reason \\ "device_revoked")

  def disable_for_device(tenant_id, user_id, device_id, reason)
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) do
    disable_where(
      dynamic(
        [subscription],
        subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id and
          subscription.device_id == ^device_id
      ),
      reason
    )
  end

  def disable_for_device(_, _, _, _), do: :ok

  def disable_for_user(tenant_id, user_id, reason \\ "user_revoked")

  def disable_for_user(tenant_id, user_id, reason)
      when is_binary(tenant_id) and is_binary(user_id) do
    disable_where(
      dynamic(
        [subscription],
        subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id
      ),
      reason
    )
  end

  def disable_for_user(_, _, _), do: :ok

  defp insert_subscription!(normalized, subject) do
    subscription = %PushSubscription{id: Ecto.UUID.generate()}
    encrypted = encrypt_subscription!(subscription.id, 1, normalized, subject)

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
        current = decrypt_subscription!(existing)

        if current == normalized.payload do
          %{subscription: existing, replayed: true}
        else
          version = existing.version + 1
          encrypted = encrypt_subscription!(existing.id, version, normalized, subject)

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
    encrypted = encrypt_subscription!(existing.id, version, normalized, subject)

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

  defp normalize_subscription(attrs) do
    endpoint_value = value(attrs, :endpoint)
    keys = value(attrs, :keys)

    with {:ok, endpoint, endpoint_hint} <- validate_endpoint(endpoint_value),
         {:ok, p256dh} <- validate_key(value(keys || %{}, :p256dh), :p256dh),
         {:ok, auth} <- validate_key(value(keys || %{}, :auth), :auth),
         {:ok, expiration_time, expires_at} <- validate_expiration(value(attrs, :expiration_time)) do
      payload = %{
        "endpoint" => endpoint,
        "expirationTime" => expiration_time,
        "keys" => %{"p256dh" => p256dh, "auth" => auth},
        "version" => @subscription_format_version
      }

      {:ok,
       %{
         endpoint_hash: :crypto.hash(:sha256, endpoint),
         endpoint_hint: endpoint_hint,
         expires_at: expires_at,
         payload: payload,
         json: Jason.encode!(payload)
       }}
    end
  end

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    endpoint = String.trim(endpoint)
    uri = URI.parse(endpoint)

    cond do
      endpoint == "" or byte_size(endpoint) > @max_endpoint_bytes ->
        {:error, :invalid_push_endpoint}

      Regex.match?(~r/[\x00-\x20\x7F]/, endpoint) ->
        {:error, :invalid_push_endpoint}

      String.downcase(uri.scheme || "") != "https" or not is_binary(uri.host) or uri.host == "" ->
        {:error, :invalid_push_endpoint}

      not is_nil(uri.userinfo) or not is_nil(uri.fragment) ->
        {:error, :invalid_push_endpoint}

      true ->
        normalized =
          uri
          |> Map.put(:scheme, "https")
          |> Map.put(:host, String.downcase(uri.host))
          |> URI.to_string()

        {:ok, normalized, String.downcase(uri.host)}
    end
  end

  defp validate_endpoint(_), do: {:error, :invalid_push_endpoint}

  defp validate_key(value, kind) when is_binary(value) do
    max_bytes = if kind == :p256dh, do: 128, else: 64

    with true <- byte_size(value) > 0 and byte_size(value) <= max_bytes,
         true <- Regex.match?(~r/^[A-Za-z0-9_-]+$/, value),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- valid_decoded_key?(decoded, kind) do
      {:ok, value}
    else
      _ -> {:error, invalid_key_error(kind)}
    end
  end

  defp validate_key(_, kind), do: {:error, invalid_key_error(kind)}
  defp valid_decoded_key?(<<4, _::binary-size(64)>>, :p256dh), do: true
  defp valid_decoded_key?(value, :auth), do: byte_size(value) == 16
  defp valid_decoded_key?(_, _), do: false
  defp invalid_key_error(:p256dh), do: :invalid_push_p256dh_key
  defp invalid_key_error(:auth), do: :invalid_push_auth_key

  defp validate_expiration(nil), do: {:ok, nil, nil}

  defp validate_expiration(value) when is_integer(value) and value > 0 do
    with {:ok, expires_at} <- DateTime.from_unix(value, :millisecond),
         true <- DateTime.compare(expires_at, now()) == :gt,
         true <- DateTime.diff(expires_at, now(), :second) <= @max_expiration_seconds do
      {:ok, value, DateTime.truncate(expires_at, :microsecond)}
    else
      _ -> {:error, :invalid_push_expiration}
    end
  end

  defp validate_expiration(_), do: {:error, :invalid_push_expiration}

  defp encrypt_subscription!(subscription_id, version, normalized, subject) do
    normalized.json
    |> PushSubscriptionBox.encrypt(%{
      tenant_id: value(subject, :tenant_id),
      subscription_id: subscription_id,
      version: version
    })
    |> unwrap_or_rollback()
  end

  defp decrypt_subscription!(subscription) do
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
         true <- valid_materialized_subscription?(decoded) do
      decoded
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:invalid_encrypted_push_subscription)
    end
  end

  defp valid_materialized_subscription?(%{
         "version" => @subscription_format_version,
         "endpoint" => endpoint,
         "keys" => %{"p256dh" => p256dh, "auth" => auth}
       }) do
    match?({:ok, _, _}, validate_endpoint(endpoint)) and
      match?({:ok, _}, validate_key(p256dh, :p256dh)) and
      match?({:ok, _}, validate_key(auth, :auth))
  end

  defp valid_materialized_subscription?(_), do: false

  defp disable!(subscription, status, reason) when status in @terminal_statuses do
    timestamp = now()

    attrs =
      %{status: status, disabled_reason: String.slice(to_string(reason), 0, 120)}
      |> maybe_put(:revoked_at, status == :revoked, timestamp)
      |> maybe_put(:stale_at, status == :stale, timestamp)

    subscription
    |> PushSubscription.changeset(attrs)
    |> Repo.update!()
  end

  defp disable_where(filter, reason) do
    timestamp = now()

    PushSubscription
    |> where(^filter)
    |> where([subscription], subscription.status == :active)
    |> Repo.update_all(
      set: [
        status: :revoked,
        revoked_at: timestamp,
        disabled_reason: String.slice(to_string(reason), 0, 120),
        updated_at: timestamp
      ]
    )

    :ok
  end

  defp expire_due(tenant_id, user_id, device_id) do
    timestamp = now()

    PushSubscription
    |> where(
      [subscription],
      subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id and
        subscription.status == :active and not is_nil(subscription.expires_at) and
        subscription.expires_at <= ^timestamp
    )
    |> maybe_device(device_id)
    |> Repo.update_all(
      set: [status: :expired, disabled_reason: "subscription_expired", updated_at: timestamp]
    )

    :ok
  end

  defp maybe_device(query, nil), do: query

  defp maybe_device(query, device_id),
    do: where(query, [subscription], subscription.device_id == ^device_id)

  defp expired?(%PushSubscription{expires_at: nil}), do: false

  defp expired?(%PushSubscription{expires_at: expires_at}),
    do: DateTime.compare(expires_at, now()) != :gt

  defp delivery_eligible?(subscription_id, version, tenant_id) do
    PushSubscription
    |> join(:inner, [subscription], user in User,
      on:
        user.tenant_id == subscription.tenant_id and user.id == subscription.user_id and
          user.status == :active and user.account_type == :human
    )
    |> join(:inner, [subscription, _user], device in Device,
      on:
        device.tenant_id == subscription.tenant_id and device.user_id == subscription.user_id and
          device.id == subscription.device_id and is_nil(device.revoked_at)
    )
    |> where(
      [subscription, _user, _device],
      subscription.id == ^subscription_id and subscription.tenant_id == ^tenant_id and
        subscription.version == ^version and subscription.status == :active and
        (is_nil(subscription.expires_at) or subscription.expires_at > ^now())
    )
    |> Repo.exists?()
  end

  defp terminal_error(:revoked), do: :push_subscription_revoked
  defp terminal_error(:expired), do: :push_subscription_expired
  defp terminal_error(:stale), do: :push_subscription_stale

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

  defp ensure_active_identity!(subject) do
    eligible? =
      Device
      |> join(:inner, [device], user in User,
        on:
          user.tenant_id == device.tenant_id and user.id == device.user_id and
            user.status == :active and user.account_type == :human
      )
      |> where(
        [device, user],
        device.tenant_id == ^value(subject, :tenant_id) and
          device.user_id == ^value(subject, :user_id) and
          device.id == ^value(subject, :device_id) and is_nil(device.revoked_at) and
          user.id == ^value(subject, :user_id)
      )
      |> Repo.exists?()

    unless eligible?, do: Repo.rollback(:forbidden)
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

  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, false, _value), do: map
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
