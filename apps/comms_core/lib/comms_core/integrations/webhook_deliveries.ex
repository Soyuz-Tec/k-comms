defmodule CommsCore.Integrations.WebhookDeliveries do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Audit

  alias CommsCore.Integrations.{
    Policy,
    WebhookDelivery,
    WebhookDeliveryClaim,
    WebhookDispatchRequest,
    WebhookEndpoint,
    WebhookSecrets,
    WebhookSubscription
  }

  alias CommsCore.Outbox.Event
  alias CommsCore.{Repo, RuntimePorts}

  @claim_timeout_seconds 300
  @max_list_limit 100
  @sensitive_keys ~w(authorization cookie password password_hash refresh_token secret token webhook_secret)

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

  def create(attrs) when is_map(attrs) do
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

  def claim(id) when is_binary(id) do
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

  def request(%WebhookDeliveryClaim{} = claimed) do
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
        true -> materialize_request!(delivery, endpoint)
      end
    end)
    |> unwrap_transaction()
  end

  def record(%WebhookDeliveryClaim{} = claim, result) do
    Repo.transaction(fn ->
      locked =
        Repo.one!(
          from(delivery in WebhookDelivery, where: delivery.id == ^claim.id, lock: "FOR UPDATE")
        )

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

  def list(subject, opts \\ %{}) do
    with :ok <- Policy.authorize_read(subject) do
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

  def replay(id, subject) do
    with :ok <- Policy.authorize_manage(subject) do
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
              create(%{
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

  def active_in_progress?(%WebhookEndpoint{} = endpoint) do
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

  def terminalize_endpoint!(%WebhookEndpoint{} = endpoint, reason) do
    from(delivery in WebhookDelivery,
      where:
        delivery.endpoint_id == ^endpoint.id and delivery.tenant_id == ^endpoint.tenant_id and
          delivery.status in [:pending, :delivering, :retryable]
    )
    |> terminalize!(reason)
  end

  def terminalize_secret_version!(%WebhookEndpoint{} = endpoint, secret_version, reason) do
    from(delivery in WebhookDelivery,
      where:
        delivery.endpoint_id == ^endpoint.id and delivery.tenant_id == ^endpoint.tenant_id and
          delivery.secret_version == ^secret_version and
          delivery.status in [:pending, :delivering, :retryable]
    )
    |> terminalize!(reason)
  end

  defp insert_delivery(changeset) do
    if Repo.in_transaction?() do
      Repo.insert(changeset, mode: :savepoint)
    else
      Repo.insert(changeset)
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
          create(%{
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

  defp terminalize!(query, reason) do
    Repo.update_all(query,
      set: [
        status: :failed,
        claimed_at: nil,
        claim_token: nil,
        last_error_code: reason,
        updated_at: now()
      ]
    )
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

  defp materialize_request!(%WebhookDelivery{} = delivery, %WebhookEndpoint{} = endpoint) do
    struct!(WebhookDispatchRequest, %{
      url: endpoint.url,
      secret: WebhookSecrets.materialize!(delivery, endpoint),
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
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
