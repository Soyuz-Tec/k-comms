defmodule CommsCore.Integrations do
  import Ecto.Query

  alias CommsCore.Audit
  alias CommsCore.Authorization
  alias CommsCore.Outbox.Event

  alias CommsCore.Integrations.{
    WebhookDelivery,
    WebhookDeliveryClaim,
    WebhookDispatchRequest,
    WebhookEndpoint,
    WebhookSecret,
    WebhookSubscription
  }

  alias CommsCore.{Repo, RuntimePorts}
  alias CommsCore.Security.SecretBox

  @claim_timeout_seconds 300
  @max_list_limit 100
  @sensitive_keys ~w(authorization cookie password password_hash refresh_token secret token webhook_secret)

  def list_endpoint_views(subject) do
    with {:ok, endpoints} <- list_endpoints(subject) do
      {:ok, Enum.map(endpoints, &CommsCore.Integrations.Projector.endpoint/1)}
    end
  end

  def get_endpoint_view(id, subject),
    do: get_endpoint(id, subject) |> project_result(&CommsCore.Integrations.Projector.endpoint/1)

  def create_endpoint_view(attrs, subject) do
    with {:ok, result} <- create_endpoint(attrs, subject) do
      {:ok, %{result | endpoint: CommsCore.Integrations.Projector.endpoint(result.endpoint)}}
    end
  end

  def update_endpoint_view(id, attrs, subject),
    do:
      update_endpoint(id, attrs, subject)
      |> project_result(&CommsCore.Integrations.Projector.endpoint/1)

  def disable_endpoint_view(id, subject),
    do:
      disable_endpoint(id, subject)
      |> project_result(&CommsCore.Integrations.Projector.endpoint/1)

  def rotate_secret_view(id, subject) do
    with {:ok, result} <- rotate_secret(id, subject) do
      {:ok, %{result | endpoint: CommsCore.Integrations.Projector.endpoint(result.endpoint)}}
    end
  end

  def list_delivery_views(subject, opts \\ %{}) do
    with {:ok, deliveries} <- list_deliveries(subject, opts) do
      {:ok, Enum.map(deliveries, &CommsCore.Integrations.Projector.delivery/1)}
    end
  end

  def replay_delivery_view(id, subject),
    do:
      replay_delivery(id, subject) |> project_result(&CommsCore.Integrations.Projector.delivery/1)

  def status, do: %{secret_storage: SecretBox.status()}

  def list_endpoints(subject) do
    with :ok <- authorize_read(subject) do
      endpoints =
        WebhookEndpoint
        |> where([endpoint], endpoint.tenant_id == ^value(subject, :tenant_id))
        |> order_by([endpoint], asc: endpoint.name)
        |> preload(:subscriptions)
        |> Repo.all()

      {:ok, endpoints}
    end
  end

  def get_endpoint(id, subject) do
    with :ok <- authorize_read(subject),
         %WebhookEndpoint{} = endpoint <-
           WebhookEndpoint
           |> where(
             [endpoint],
             endpoint.id == ^id and endpoint.tenant_id == ^value(subject, :tenant_id)
           )
           |> preload(:subscriptions)
           |> Repo.one() do
      {:ok, endpoint}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def create_endpoint(attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage(subject),
         {:ok, event_types} <- validate_event_types(value(attrs, :event_types)),
         secret <- generate_secret() do
      Repo.transaction(fn ->
        endpoint =
          %WebhookEndpoint{}
          |> WebhookEndpoint.changeset(%{
            tenant_id: value(subject, :tenant_id),
            created_by_user_id: value(subject, :user_id),
            name: value(attrs, :name),
            url: value(attrs, :url),
            status: :active,
            secret_version: 1
          })
          |> Repo.insert!()

        encrypted =
          secret
          |> SecretBox.encrypt(secret_context(endpoint, 1))
          |> unwrap_or_rollback()

        insert_secret!(endpoint, 1, encrypted)
        replace_subscriptions!(endpoint, event_types)

        audit!(subject, "webhook_endpoint.created", "webhook_endpoint", endpoint.id, %{
          event_types: event_types,
          host: endpoint_host(endpoint.url)
        })

        %{endpoint: Repo.preload(endpoint, :subscriptions, force: true), secret: secret}
      end)
      |> unwrap_transaction()
    end
  end

  def update_endpoint(id, attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage(subject),
         {:ok, event_types} <- maybe_event_types(attrs) do
      Repo.transaction(fn ->
        endpoint = locked_endpoint!(id, subject)
        previous_url = endpoint.url
        status = normalize_status(value(attrs, :status), endpoint.status)
        disabled_at = if status == :disabled, do: endpoint.disabled_at || now(), else: nil
        requested_url = value(attrs, :url)

        destination_change? =
          status == :disabled or (is_binary(requested_url) and requested_url != previous_url)

        if destination_change? and active_delivery_in_progress?(endpoint) do
          Repo.rollback(:conflict)
        end

        endpoint =
          endpoint
          |> WebhookEndpoint.changeset(
            drop_nil(%{
              name: value(attrs, :name),
              url: value(attrs, :url),
              status: status,
              disabled_at: disabled_at
            })
          )
          |> Repo.update!()

        if is_list(event_types), do: replace_subscriptions!(endpoint, event_types)

        cond do
          endpoint.status == :disabled ->
            fail_pending_deliveries!(endpoint, "endpoint_disabled")

          endpoint.url != previous_url ->
            fail_pending_deliveries!(endpoint, "endpoint_configuration_changed")

          true ->
            :ok
        end

        audit!(subject, "webhook_endpoint.updated", "webhook_endpoint", endpoint.id, %{
          status: endpoint.status,
          host: endpoint_host(endpoint.url),
          subscriptions_changed: is_list(event_types)
        })

        Repo.preload(endpoint, :subscriptions, force: true)
      end)
      |> unwrap_transaction()
    end
  end

  def disable_endpoint(id, subject) do
    update_endpoint(id, %{status: :disabled}, subject)
  end

  def rotate_secret(id, subject) do
    with :ok <- authorize_manage(subject),
         secret <- generate_secret() do
      Repo.transaction(fn ->
        endpoint = locked_endpoint!(id, subject)

        if active_delivery_in_progress?(endpoint) do
          Repo.rollback(:conflict)
        end

        version = endpoint.secret_version + 1

        encrypted =
          secret
          |> SecretBox.encrypt(secret_context(endpoint, version))
          |> unwrap_or_rollback()

        from(existing in WebhookSecret,
          where:
            existing.endpoint_id == ^endpoint.id and existing.version == ^endpoint.secret_version and
              is_nil(existing.retired_at)
        )
        |> Repo.update_all(set: [retired_at: now()])

        insert_secret!(endpoint, version, encrypted)

        endpoint =
          endpoint
          |> WebhookEndpoint.changeset(%{secret_version: version})
          |> Repo.update!()

        audit!(subject, "webhook_endpoint.secret_rotated", "webhook_endpoint", endpoint.id, %{
          secret_version: version
        })

        %{endpoint: endpoint, secret: secret}
      end)
      |> unwrap_transaction()
    end
  end

  def enqueue_for_event(%Event{} = event) do
    endpoints =
      from(endpoint in WebhookEndpoint,
        join: subscription in WebhookSubscription,
        on:
          subscription.endpoint_id == endpoint.id and
            subscription.tenant_id == endpoint.tenant_id,
        where:
          endpoint.tenant_id == ^event.tenant_id and endpoint.status == :active and
            subscription.event_type == ^event.event_type,
        select: endpoint
      )
      |> Repo.all()

    Enum.reduce_while(endpoints, :ok, fn endpoint, :ok ->
      case enqueue_event_delivery(event, endpoint) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def create_delivery(attrs) when is_map(attrs) do
    changeset = WebhookDelivery.changeset(%WebhookDelivery{}, attrs)

    case insert_delivery(changeset) do
      {:error, changeset} ->
        if conflict?(changeset, :idempotency_key) do
          delivery =
            Repo.get_by!(WebhookDelivery,
              tenant_id: value(attrs, :tenant_id),
              idempotency_key: value(attrs, :idempotency_key)
            )

          with :ok <- maybe_enqueue_delivery(delivery), do: {:ok, delivery}
        else
          {:error, changeset}
        end

      {:ok, %WebhookDelivery{} = delivery} ->
        with :ok <- maybe_enqueue_delivery(delivery), do: {:ok, delivery}
    end
  end

  defp insert_delivery(changeset) do
    if Repo.in_transaction?() do
      Repo.insert(changeset, mode: :savepoint)
    else
      Repo.insert(changeset)
    end
  end

  def claim_delivery(id) when is_binary(id) do
    Repo.transaction(fn ->
      reference = Repo.get(WebhookDelivery, id) || Repo.rollback(:not_found)

      endpoint =
        Repo.one(
          from(endpoint in WebhookEndpoint,
            where:
              endpoint.id == ^reference.endpoint_id and endpoint.tenant_id == ^reference.tenant_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      delivery =
        Repo.one(from(delivery in WebhookDelivery, where: delivery.id == ^id, lock: "FOR UPDATE")) ||
          Repo.rollback(:not_found)

      cond do
        delivery.endpoint_id != endpoint.id -> Repo.rollback(:not_found)
        delivery.tenant_id != endpoint.tenant_id -> Repo.rollback(:not_found)
        delivery.status == :delivered -> :already_delivered
        delivery.status == :failed -> Repo.rollback(:terminal_delivery)
        endpoint.status != :active -> Repo.rollback(:endpoint_disabled)
        claimable?(delivery) -> delivery |> update_claim!() |> delivery_claim()
        true -> Repo.rollback(:not_claimable)
      end
    end)
    |> unwrap_transaction()
  end

  def delivery_request(%WebhookDeliveryClaim{} = claimed) do
    Repo.transaction(fn ->
      reference = Repo.get(WebhookDelivery, claimed.id) || Repo.rollback(:not_found)

      endpoint =
        Repo.one(
          from(endpoint in WebhookEndpoint,
            where:
              endpoint.id == ^reference.endpoint_id and endpoint.tenant_id == ^reference.tenant_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:webhook_endpoint_unavailable)

      delivery =
        Repo.one(
          from(delivery in WebhookDelivery,
            where: delivery.id == ^claimed.id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      cond do
        delivery.tenant_id != endpoint.tenant_id -> Repo.rollback(:stale_delivery_claim)
        delivery.endpoint_id != endpoint.id -> Repo.rollback(:stale_delivery_claim)
        endpoint.status != :active -> Repo.rollback(:endpoint_disabled)
        not current_claim?(delivery, claimed) -> Repo.rollback(:stale_delivery_claim)
        true -> materialize_delivery_request!(delivery, endpoint)
      end
    end)
    |> unwrap_transaction()
  end

  def record_delivery(%WebhookDeliveryClaim{} = claim, result) do
    Repo.transaction(fn ->
      locked =
        Repo.one!(from(d in WebhookDelivery, where: d.id == ^claim.id, lock: "FOR UPDATE"))

      unless current_claim?(locked, claim) do
        Repo.rollback(:stale_delivery_claim)
      end

      completed_at = now()
      attempt_count = locked.attempt_count + 1

      locked
      |> WebhookDelivery.changeset(delivery_result_attrs(result, attempt_count, completed_at))
      |> Repo.update!()

      :recorded
    end)
    |> unwrap_transaction()
  end

  def list_deliveries(subject, opts \\ %{}) do
    with :ok <- authorize_read(subject) do
      query =
        WebhookDelivery
        |> where([delivery], delivery.tenant_id == ^value(subject, :tenant_id))
        |> maybe_filter(:endpoint_id, value(opts, :endpoint_id))
        |> maybe_filter(:status, normalize_delivery_status(value(opts, :status)))
        |> order_by([delivery], desc: delivery.inserted_at)
        |> limit(^limit(opts))
        |> preload(:endpoint)

      {:ok, Repo.all(query)}
    end
  end

  def replay_delivery(id, subject) do
    with :ok <- authorize_manage(subject) do
      tenant_id = value(subject, :tenant_id)

      case Repo.get_by(WebhookDelivery, id: id, tenant_id: tenant_id) do
        nil ->
          {:error, :not_found}

        reference ->
          Repo.transaction(fn ->
            endpoint =
              Repo.one(
                from(endpoint in WebhookEndpoint,
                  where:
                    endpoint.id == ^reference.endpoint_id and endpoint.tenant_id == ^tenant_id,
                  lock: "FOR UPDATE"
                )
              ) || Repo.rollback(:not_found)

            if endpoint.status != :active, do: Repo.rollback(:endpoint_disabled)

            source =
              Repo.one(
                from(delivery in WebhookDelivery,
                  where:
                    delivery.id == ^id and delivery.tenant_id == ^tenant_id and
                      delivery.endpoint_id == ^endpoint.id,
                  lock: "FOR UPDATE"
                )
              ) || Repo.rollback(:not_found)

            delivery =
              create_delivery(%{
                tenant_id: source.tenant_id,
                endpoint_id: source.endpoint_id,
                outbox_event_id: source.outbox_event_id,
                event_type: source.event_type,
                payload: source.payload,
                idempotency_key: "replay:#{source.id}:#{Ecto.UUID.generate()}",
                secret_version: endpoint.secret_version,
                status: :pending,
                next_attempt_at: now()
              })
              |> unwrap_or_rollback()

            audit!(subject, "webhook_delivery.replayed", "webhook_delivery", delivery.id, %{
              source_delivery_id: source.id,
              endpoint_id: source.endpoint_id
            })

            delivery
          end)
          |> unwrap_transaction()
      end
    end
  end

  defp enqueue_event_delivery(%Event{} = event, %WebhookEndpoint{} = expected_endpoint) do
    Repo.transaction(fn ->
      endpoint =
        Repo.one(
          from(endpoint in WebhookEndpoint,
            where:
              endpoint.id == ^expected_endpoint.id and endpoint.tenant_id == ^event.tenant_id,
            lock: "FOR UPDATE"
          )
        )

      case endpoint_delivery_disposition(endpoint, expected_endpoint, event.event_type) do
        :skip ->
          :ok

        {:create, status, secret_version, error_code} ->
          create_delivery(%{
            tenant_id: event.tenant_id,
            endpoint_id: endpoint.id,
            outbox_event_id: event.id,
            event_type: event.event_type,
            payload: event_payload(event),
            idempotency_key: "outbox:#{event.id}:endpoint:#{endpoint.id}",
            secret_version: secret_version,
            status: status,
            next_attempt_at: now(),
            last_error_code: error_code
          })
          |> case do
            {:ok, _delivery} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoint_delivery_disposition(nil, _expected_endpoint, _event_type), do: :skip

  defp endpoint_delivery_disposition(endpoint, expected_endpoint, event_type) do
    subscribed? =
      Repo.exists?(
        from(subscription in WebhookSubscription,
          where:
            subscription.endpoint_id == ^endpoint.id and
              subscription.tenant_id == ^endpoint.tenant_id and
              subscription.event_type == ^event_type
        )
      )

    cond do
      endpoint.status != :active ->
        {:create, :failed, expected_endpoint.secret_version, "endpoint_disabled"}

      endpoint.url != expected_endpoint.url ->
        {:create, :failed, expected_endpoint.secret_version, "endpoint_configuration_changed"}

      endpoint.secret_version != expected_endpoint.secret_version ->
        {:create, :failed, expected_endpoint.secret_version, "endpoint_secret_rotated"}

      not subscribed? ->
        {:create, :failed, expected_endpoint.secret_version, "endpoint_subscription_changed"}

      true ->
        {:create, :pending, endpoint.secret_version, nil}
    end
  end

  defp insert_secret!(endpoint, version, encrypted) do
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

  defp replace_subscriptions!(endpoint, event_types) do
    Repo.delete_all(from(s in WebhookSubscription, where: s.endpoint_id == ^endpoint.id))

    Enum.each(event_types, fn event_type ->
      %WebhookSubscription{}
      |> WebhookSubscription.changeset(%{
        tenant_id: endpoint.tenant_id,
        endpoint_id: endpoint.id,
        event_type: event_type
      })
      |> Repo.insert!()
    end)
  end

  defp fail_pending_deliveries!(endpoint, reason) do
    from(delivery in WebhookDelivery,
      where:
        delivery.endpoint_id == ^endpoint.id and delivery.tenant_id == ^endpoint.tenant_id and
          delivery.status in [:pending, :delivering, :retryable]
    )
    |> Repo.update_all(
      set: [
        status: :failed,
        claimed_at: nil,
        claim_token: nil,
        last_error_code: reason,
        updated_at: now()
      ]
    )
  end

  defp active_delivery_in_progress?(endpoint) do
    cutoff = DateTime.add(now(), -@claim_timeout_seconds, :second)

    Repo.exists?(
      from(delivery in WebhookDelivery,
        where:
          delivery.endpoint_id == ^endpoint.id and delivery.tenant_id == ^endpoint.tenant_id and
            delivery.status == :delivering and not is_nil(delivery.claimed_at) and
            delivery.claimed_at > ^cutoff
      )
    )
  end

  defp locked_endpoint!(id, subject) do
    Repo.one(
      from(endpoint in WebhookEndpoint,
        where: endpoint.id == ^id and endpoint.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp validate_event_types(values) when is_list(values) do
    event_types =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      event_types == [] ->
        {:error, :webhook_event_types_required}

      length(event_types) > 50 ->
        {:error, :too_many_webhook_event_types}

      Enum.all?(event_types, &Regex.match?(~r/^[a-z][a-z0-9_.-]{2,119}$/, &1)) ->
        {:ok, event_types}

      true ->
        {:error, :invalid_webhook_event_type}
    end
  end

  defp validate_event_types(_), do: {:error, :webhook_event_types_required}

  defp maybe_event_types(attrs) do
    if Map.has_key?(attrs, :event_types) or Map.has_key?(attrs, "event_types") do
      validate_event_types(value(attrs, :event_types))
    else
      {:ok, nil}
    end
  end

  defp event_payload(event) do
    %{
      "id" => event.id,
      "type" => event.event_type,
      "occurred_at" => DateTime.to_iso8601(event.inserted_at || now()),
      "data" => redact(event.payload),
      "aggregate" => %{"type" => event.aggregate_type, "id" => event.aggregate_id}
    }
  end

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, val} ->
      key_string = to_string(key)

      if String.downcase(key_string) in @sensitive_keys do
        {key_string, "[REDACTED]"}
      else
        {key_string, redact(val)}
      end
    end)
  end

  defp redact(values) when is_list(values), do: Enum.take(values, 100) |> Enum.map(&redact/1)
  defp redact(value) when is_binary(value), do: String.slice(value, 0, 10_000)
  defp redact(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp redact(_), do: "[UNSUPPORTED]"

  defp enqueue_job(delivery) do
    %{"delivery_id" => delivery.id, "tenant_id" => delivery.tenant_id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:webhook_delivery),
      queue: :webhooks,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_enqueue_delivery(%WebhookDelivery{status: status})
       when status in [:delivered, :failed],
       do: :ok

  defp maybe_enqueue_delivery(delivery), do: enqueue_job(delivery)

  defp claimable?(delivery) do
    due =
      is_nil(delivery.next_attempt_at) or DateTime.compare(delivery.next_attempt_at, now()) != :gt

    stale =
      is_nil(delivery.claimed_at) or
        DateTime.diff(now(), delivery.claimed_at, :second) >= @claim_timeout_seconds

    (delivery.status in [:pending, :retryable] and due) or
      (delivery.status == :delivering and stale)
  end

  defp update_claim!(delivery) do
    delivery
    |> WebhookDelivery.changeset(%{
      status: :delivering,
      claimed_at: now(),
      claim_generation: delivery.claim_generation + 1,
      claim_token: Ecto.UUID.generate()
    })
    |> Repo.update!()
  end

  defp delivery_claim(%WebhookDelivery{} = delivery) do
    struct!(WebhookDeliveryClaim, %{
      id: delivery.id,
      claim_generation: delivery.claim_generation,
      claim_token: delivery.claim_token
    })
  end

  defp materialize_delivery_request!(%WebhookDelivery{} = delivery, %WebhookEndpoint{} = endpoint) do
    secret =
      Repo.get_by(WebhookSecret,
        tenant_id: delivery.tenant_id,
        endpoint_id: delivery.endpoint_id,
        version: delivery.secret_version
      ) || Repo.rollback(:webhook_secret_unavailable)

    plaintext =
      SecretBox.decrypt(
        %{
          ciphertext: secret.ciphertext,
          nonce: secret.nonce,
          tag: secret.tag,
          key_id: secret.key_id
        },
        secret_context(delivery, delivery.secret_version)
      )
      |> unwrap_or_rollback()

    struct!(WebhookDispatchRequest, %{
      url: endpoint.url,
      secret: plaintext,
      body: delivery.payload,
      event_type: delivery.event_type,
      delivery_id: delivery.id,
      idempotency_key: delivery.idempotency_key
    })
  end

  defp delivery_result_attrs(result, attempt_count, completed_at) do
    metadata = result_metadata(result)

    case result_status(result) do
      :delivered ->
        %{
          status: :delivered,
          attempt_count: attempt_count,
          last_attempt_at: completed_at,
          delivered_at: completed_at,
          claimed_at: nil,
          claim_token: nil,
          response_status: metadata.response_status,
          last_error_code: nil
        }

      status ->
        %{
          status: status,
          attempt_count: attempt_count,
          next_attempt_at: DateTime.add(completed_at, retry_delay(attempt_count), :second),
          last_attempt_at: completed_at,
          claimed_at: nil,
          claim_token: nil,
          response_status: metadata.response_status,
          last_error_code: metadata.error_code
        }
    end
  end

  defp result_status({:ok, _}), do: :delivered
  defp result_status(:ok), do: :delivered
  defp result_status({:error, :permanent, _}), do: :failed
  defp result_status({:error, _}), do: :retryable

  defp result_metadata({:ok, metadata}) when is_map(metadata) do
    %{response_status: safe_integer(value(metadata, :http_status)), error_code: nil}
  end

  defp result_metadata(:ok), do: %{response_status: nil, error_code: nil}

  defp result_metadata({:error, :permanent, reason}),
    do: %{response_status: error_status(reason), error_code: safe_error_code(reason)}

  defp result_metadata({:error, reason}),
    do: %{response_status: error_status(reason), error_code: safe_error_code(reason)}

  defp error_status({:webhook_status, status}) when is_integer(status), do: status
  defp error_status(_), do: nil

  defp safe_error_code({kind, status}) when is_atom(kind) and is_integer(status),
    do: "#{kind}_#{status}"

  defp safe_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_code(_), do: "provider_error"

  defp retry_delay(attempt), do: min(round(:math.pow(2, min(attempt, 10))), 900)
  defp generate_secret, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp endpoint_host(url), do: URI.parse(url).host
  defp normalize_status(value, _current) when value in [:active, "active"], do: :active
  defp normalize_status(value, _current) when value in [:disabled, "disabled"], do: :disabled
  defp normalize_status(_, current), do: current
  defp normalize_delivery_status(nil), do: nil

  defp normalize_delivery_status(value)
       when value in [:pending, :delivering, :retryable, :delivered, :failed],
       do: value

  defp normalize_delivery_status(value) when is_binary(value) do
    case value do
      "pending" -> :pending
      "delivering" -> :delivering
      "retryable" -> :retryable
      "delivered" -> :delivered
      "failed" -> :failed
      _ -> nil
    end
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, :endpoint_id, value),
    do: where(query, [delivery], delivery.endpoint_id == ^value)

  defp maybe_filter(query, :status, value),
    do: where(query, [delivery], delivery.status == ^value)

  defp limit(opts), do: value(opts, :limit) |> integer(50) |> min(@max_list_limit) |> max(1)
  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp safe_integer(value) when is_integer(value), do: value
  defp safe_integer(_), do: nil

  defp current_claim?(locked, claimed) do
    locked.status == :delivering and is_binary(claimed.claim_token) and
      locked.claim_token == claimed.claim_token and
      locked.claim_generation == claimed.claim_generation
  end

  defp authorize_read(subject), do: Authorization.authorize(:administer_tenant, subject, %{})
  defp authorize_manage(subject), do: Authorization.authorize(:manage_integrations, subject, %{})

  defp audit!(subject, action, resource_type, resource_id, metadata) do
    Audit.record(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp drop_nil(map), do: Map.reject(map, fn {_key, val} -> is_nil(val) end)

  defp conflict?(changeset, field) do
    Keyword.has_key?(changeset.errors, field) or
      Enum.any?(changeset.errors, fn {_error_field, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          metadata[:constraint_name] ==
            "webhook_deliveries_tenant_id_idempotency_key_index"
      end)
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

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
