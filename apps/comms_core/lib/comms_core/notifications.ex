defmodule CommsCore.Notifications do
  import Ecto.Query

  alias CommsCore.Accounts.User
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Authorization
  alias CommsCore.Conversations.Membership
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Notifications.{Attempt, Intent, Preference}
  alias CommsCore.PushSubscriptions
  alias CommsCore.Repo

  @worker "CommsWorkers.NotificationWorker"
  @claim_timeout_seconds 300
  @max_list_limit 100
  @recovery_event_type "account.password_recovery.requested.v1"
  @payload_keys ~w(title body action_url conversation_id message_id sender_user_id aggregate_id aggregate_type event_id recovery_request_id)

  def get_preferences(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    Repo.get_by(Preference, tenant_id: tenant_id, user_id: user_id) ||
      %Preference{
        tenant_id: tenant_id,
        user_id: user_id,
        email_enabled: true,
        push_enabled: false,
        in_app_enabled: true,
        muted_event_types: []
      }
  end

  def update_preferences(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    changes = %{
      email_enabled: value(attrs, :email_enabled),
      push_enabled: value(attrs, :push_enabled),
      in_app_enabled: value(attrs, :in_app_enabled),
      muted_event_types: normalize_event_types(value(attrs, :muted_event_types))
    }

    existing = Repo.get_by(Preference, tenant_id: tenant_id, user_id: user_id)

    (existing || %Preference{tenant_id: tenant_id, user_id: user_id})
    |> Preference.changeset(drop_nil(changes))
    |> Repo.insert_or_update()
  end

  def list_intents(subject, opts \\ %{}) do
    limit = limit(opts)
    scope = value(opts, :scope)
    tenant_id = value(subject, :tenant_id)

    with :ok <- authorize_scope(scope, subject) do
      query =
        Intent
        |> where([intent], intent.tenant_id == ^tenant_id)
        |> where([intent], intent.event_type != @recovery_event_type)
        |> maybe_for_user(scope, subject)
        |> order_by([intent], desc: intent.inserted_at)
        |> limit(^limit)

      {:ok, Repo.all(query)}
    end
  end

  def list_attempts(subject, opts \\ %{}) do
    limit = limit(opts)
    scope = value(opts, :scope)
    tenant_id = value(subject, :tenant_id)

    with :ok <- authorize_scope(scope, subject) do
      query =
        from(attempt in Attempt,
          join: intent in Intent,
          on: intent.id == attempt.intent_id and intent.tenant_id == attempt.tenant_id,
          where: attempt.tenant_id == ^tenant_id and intent.event_type != @recovery_event_type,
          order_by: [desc: attempt.inserted_at],
          limit: ^limit,
          preload: [intent: intent]
        )
        |> maybe_attempts_for_user(scope, subject)

      {:ok, Repo.all(query)}
    end
  end

  def enqueue_for_event(%OutboxEvent{event_type: "message.created.v1"} = event) do
    sender_user_id = payload_value(event.payload, "sender_user_id")
    conversation_id = payload_value(event.payload, "conversation_id")
    excluded_user_ids = [sender_user_id | mentioned_user_ids(event)] |> Enum.filter(&is_binary/1)

    recipients =
      from(membership in Membership,
        join: user in User,
        on:
          user.id == membership.user_id and user.tenant_id == membership.tenant_id and
            user.status == :active and user.account_type == :human,
        left_join: preference in Preference,
        on: preference.user_id == user.id and preference.tenant_id == user.tenant_id,
        where:
          membership.tenant_id == ^event.tenant_id and
            membership.conversation_id == ^conversation_id and is_nil(membership.left_at) and
            user.id not in ^excluded_user_ids,
        select: {user, preference}
      )
      |> Repo.all()

    Enum.reduce_while(recipients, :ok, fn {user, preference}, :ok ->
      case enqueue_recipient_event(event, user, preference) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def enqueue_for_event(%OutboxEvent{event_type: "mention.created.v1"} = event) do
    conversation_id = payload_value(event.payload, "conversation_id")
    sender_user_id = payload_value(event.payload, "sender_user_id")
    mentioned_user_ids = mentioned_user_ids(event) |> Enum.reject(&(&1 == sender_user_id))

    recipients =
      from(membership in Membership,
        join: user in User,
        on:
          user.id == membership.user_id and user.tenant_id == membership.tenant_id and
            user.status == :active and user.account_type == :human,
        left_join: preference in Preference,
        on: preference.user_id == user.id and preference.tenant_id == user.tenant_id,
        where:
          membership.tenant_id == ^event.tenant_id and
            membership.conversation_id == ^conversation_id and is_nil(membership.left_at) and
            user.id in ^mentioned_user_ids,
        select: {user, preference}
      )
      |> Repo.all()

    Enum.reduce_while(recipients, :ok, fn {user, preference}, :ok ->
      case enqueue_recipient_event(event, user, preference) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def enqueue_for_event(%OutboxEvent{}), do: :ok

  def create_intent(attrs) when is_map(attrs) do
    now = now()

    attrs =
      attrs
      |> normalize_attrs()
      |> sanitize_intent_payload()
      |> Map.put_new(:next_attempt_at, now)
      |> Map.put_new(:status, :pending)

    changeset = Intent.changeset(%Intent{}, attrs)

    case Repo.insert(changeset) do
      {:error, changeset} when is_map(changeset) ->
        if conflict?(changeset, :idempotency_key) do
          intent =
            Repo.get_by!(Intent,
              tenant_id: Map.fetch!(attrs, :tenant_id),
              idempotency_key: Map.fetch!(attrs, :idempotency_key)
            )

          with :ok <- maybe_enqueue_intent(intent), do: {:ok, intent}
        else
          {:error, changeset}
        end

      {:ok, %Intent{} = intent} ->
        with :ok <- enqueue_job(intent), do: {:ok, intent}
    end
  end

  def claim_intent(id) when is_binary(id) do
    Repo.transaction(fn ->
      intent = Repo.one(from(i in Intent, where: i.id == ^id, lock: "FOR UPDATE"))

      cond do
        is_nil(intent) -> Repo.rollback(:not_found)
        intent.status == :delivered -> {:already_delivered, intent}
        claimable?(intent) -> update_claim!(intent)
        true -> Repo.rollback(:not_claimable)
      end
    end)
    |> unwrap_transaction()
  end

  def record_delivery(%Intent{} = intent, result) do
    Repo.transaction(fn ->
      locked = Repo.one!(from(i in Intent, where: i.id == ^intent.id, lock: "FOR UPDATE"))

      unless current_claim?(locked, intent) do
        Repo.rollback(:stale_delivery_claim)
      end

      attempt_number = locked.attempt_count + 1
      completed_at = now()
      attrs = attempt_attrs(locked, attempt_number, result, completed_at)

      %Attempt{}
      |> Attempt.changeset(attrs)
      |> Repo.insert!()

      locked
      |> Intent.changeset(intent_result_attrs(result, attempt_number, completed_at))
      |> Repo.update!()
    end)
    |> unwrap_transaction()
  end

  def retry_intent(id, subject) do
    with :ok <- Authorization.authorize(:manage_notification_delivery, subject, %{}) do
      Repo.transaction(fn ->
        intent =
          Repo.one(
            from(i in Intent,
              where:
                i.id == ^id and i.tenant_id == ^value(subject, :tenant_id) and
                  i.event_type != @recovery_event_type,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        cond do
          intent.status == :delivered -> Repo.rollback(:already_delivered)
          intent.status == :delivering -> Repo.rollback(:delivery_in_progress)
          true -> :ok
        end

        updated =
          intent
          |> Intent.changeset(%{
            status: :pending,
            next_attempt_at: now(),
            claimed_at: nil,
            claim_generation: intent.claim_generation + 1,
            claim_token: nil,
            last_error_code: nil
          })
          |> Repo.update!()

        case enqueue_job(updated) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        audit!(subject, "notification.retry", "notification_intent", updated.id, %{})
        updated
      end)
      |> unwrap_transaction()
    end
  end

  @doc false
  def enqueue_recipient_event(
        %OutboxEvent{} = event,
        %User{account_type: :human} = user,
        preference
      ) do
    muted = preference && event.event_type in preference.muted_event_types

    if muted do
      :ok
    else
      with :ok <- maybe_create_in_app(event, user, preference),
           :ok <- maybe_create_email(event, user, preference),
           :ok <- maybe_create_push(event, user, preference) do
        :ok
      end
    end
  end

  def enqueue_recipient_event(%OutboxEvent{}, %User{}, _preference), do: :ok

  defp maybe_create_in_app(event, user, preference) do
    if is_nil(preference) or preference.in_app_enabled do
      now = now()

      attrs = base_intent_attrs(event, user, :in_app, user.id)
      attrs = Map.merge(attrs, %{status: :delivered, delivered_at: now, next_attempt_at: now})

      case create_intent_without_job(attrs) do
        {:ok, intent, :created} -> notify_availability(intent)
        {:ok, _intent, :duplicate} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp maybe_create_email(event, user, preference) do
    if is_nil(preference) or preference.email_enabled do
      case create_intent(base_intent_attrs(event, user, :email, user.email)) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp maybe_create_push(event, user, %Preference{push_enabled: true}) do
    event.tenant_id
    |> PushSubscriptions.active_subscription_ids(user.id)
    |> Enum.reduce_while(:ok, fn subscription, :ok ->
      attrs =
        event
        |> base_intent_attrs(user, :push, subscription.id, subscription.id)
        |> Map.merge(%{
          push_subscription_id: subscription.id,
          push_subscription_version: subscription.version
        })

      case create_intent(attrs) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_create_push(_event, _user, _preference), do: :ok

  defp base_intent_attrs(event, user, channel, destination, idempotency_target \\ nil) do
    {title, body} = notification_copy(event.event_type)
    target_suffix = if is_binary(idempotency_target), do: ":#{idempotency_target}", else: ""

    %{
      tenant_id: event.tenant_id,
      user_id: user.id,
      event_type: event.event_type,
      channel: channel,
      destination: destination,
      idempotency_key: "outbox:#{event.id}:user:#{user.id}:#{channel}#{target_suffix}",
      payload: %{
        "title" => title,
        "body" => body,
        "conversation_id" => payload_value(event.payload, "conversation_id"),
        "message_id" => event.aggregate_id,
        "sender_user_id" => payload_value(event.payload, "sender_user_id"),
        "event_id" => event.id,
        "aggregate_id" => event.aggregate_id,
        "aggregate_type" => event.aggregate_type
      }
    }
  end

  defp notification_copy("mention.created.v1"),
    do: {"New mention", "You were mentioned in K-Comms."}

  defp notification_copy(_), do: {"New message", "You have a new message in K-Comms."}

  defp create_intent_without_job(attrs) do
    changeset = Intent.changeset(%Intent{}, attrs)

    case Repo.insert(changeset) do
      {:error, changeset} ->
        if conflict?(changeset, :idempotency_key) do
          intent =
            Repo.get_by!(Intent,
              tenant_id: attrs.tenant_id,
              idempotency_key: attrs.idempotency_key
            )

          {:ok, intent, :duplicate}
        else
          {:error, changeset}
        end

      {:ok, intent} ->
        {:ok, intent, :created}
    end
  end

  defp notify_availability(intent) do
    :comms_core
    |> Application.get_env(
      :notification_availability_notifier,
      CommsCore.Notifications.AvailabilityNotifier.Noop
    )
    |> apply(:notify, [intent])
  end

  defp enqueue_job(%Intent{channel: :in_app}), do: :ok

  defp enqueue_job(%Intent{} = intent) do
    %{
      "intent_id" => intent.id,
      "tenant_id" => intent.tenant_id,
      "dispatch_generation" => intent.claim_generation
    }
    |> Oban.Job.new(
      worker: @worker,
      queue: :notifications,
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

  defp maybe_enqueue_intent(%Intent{status: :delivered}), do: :ok
  defp maybe_enqueue_intent(intent), do: enqueue_job(intent)

  defp claimable?(%Intent{
         status: status,
         next_attempt_at: next_attempt_at,
         claimed_at: claimed_at
       }) do
    due = is_nil(next_attempt_at) or DateTime.compare(next_attempt_at, now()) != :gt

    stale =
      is_nil(claimed_at) or DateTime.diff(now(), claimed_at, :second) >= @claim_timeout_seconds

    (status in [:pending, :retryable, :failed] and due) or (status == :delivering and stale)
  end

  defp update_claim!(intent) do
    intent
    |> Intent.changeset(%{
      status: :delivering,
      claimed_at: now(),
      claim_generation: intent.claim_generation + 1,
      claim_token: Ecto.UUID.generate()
    })
    |> Repo.update!()
  end

  defp attempt_attrs(intent, attempt_number, result, completed_at) do
    metadata = result_metadata(result)

    %{
      tenant_id: intent.tenant_id,
      intent_id: intent.id,
      attempt_number: attempt_number,
      provider: metadata.provider,
      status: result_status(result),
      http_status: metadata.http_status,
      error_code: metadata.error_code,
      provider_message_id: metadata.provider_message_id,
      started_at: intent.claimed_at || completed_at,
      completed_at: completed_at
    }
  end

  defp intent_result_attrs(result, attempt_number, completed_at) do
    metadata = result_metadata(result)

    case result_status(result) do
      :delivered ->
        %{
          status: :delivered,
          attempt_count: attempt_number,
          delivered_at: completed_at,
          claimed_at: nil,
          claim_token: nil,
          last_error_code: nil
        }

      status ->
        %{
          status: status,
          attempt_count: attempt_number,
          next_attempt_at: DateTime.add(completed_at, retry_delay(attempt_number), :second),
          claimed_at: nil,
          claim_token: nil,
          last_error_code: metadata.error_code
        }
    end
  end

  defp result_status({:ok, _}), do: :delivered
  defp result_status(:ok), do: :delivered
  defp result_status({:error, :permanent, _}), do: :failed
  defp result_status({:error, _}), do: :retryable

  defp result_metadata({:ok, metadata}) when is_map(metadata) do
    %{
      provider: safe_text(value(metadata, :provider), "configured"),
      http_status: safe_integer(value(metadata, :http_status)),
      provider_message_id: safe_text(value(metadata, :provider_message_id), nil),
      error_code: nil
    }
  end

  defp result_metadata(:ok),
    do: %{provider: "configured", http_status: nil, provider_message_id: nil, error_code: nil}

  defp result_metadata({:error, :permanent, reason}), do: error_metadata(reason)
  defp result_metadata({:error, reason}), do: error_metadata(reason)

  defp error_metadata(reason) do
    %{
      provider: "configured",
      http_status: error_http_status(reason),
      provider_message_id: nil,
      error_code: safe_error_code(reason)
    }
  end

  defp error_http_status({:notification_status, status}) when is_integer(status), do: status
  defp error_http_status(_), do: nil

  defp safe_error_code({kind, status}) when is_atom(kind) and is_integer(status),
    do: "#{kind}_#{status}"

  defp safe_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_code(_), do: "provider_error"

  defp retry_delay(attempt), do: min(round(:math.pow(2, min(attempt, 10))), 900)

  defp sanitize_payload(payload) when is_map(payload) do
    payload
    |> Enum.reduce(%{}, fn {key, val}, acc ->
      key = to_string(key)

      if key in @payload_keys and safe_payload_value?(val) do
        Map.put(acc, key, truncate_payload_value(val))
      else
        acc
      end
    end)
  end

  defp sanitize_payload(_), do: %{}

  defp sanitize_intent_payload(%{event_type: @recovery_event_type} = attrs) do
    request_id = payload_value(Map.get(attrs, :payload, %{}), "recovery_request_id")

    payload =
      case Ecto.UUID.cast(request_id) do
        {:ok, _uuid} -> %{"recovery_request_id" => request_id}
        :error -> %{}
      end

    Map.put(attrs, :payload, payload)
  end

  defp sanitize_intent_payload(attrs) do
    Map.update(attrs, :payload, %{}, &sanitize_payload/1)
  end

  defp safe_payload_value?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp truncate_payload_value(value) when is_binary(value), do: String.slice(value, 0, 1_000)
  defp truncate_payload_value(value), do: value

  defp authorize_scope("tenant", subject),
    do: Authorization.authorize(:administer_tenant, subject, %{})

  defp authorize_scope(:tenant, subject), do: authorize_scope("tenant", subject)
  defp authorize_scope(_, _subject), do: :ok

  defp maybe_for_user(query, scope, _subject) when scope in ["tenant", :tenant], do: query

  defp maybe_for_user(query, _scope, subject),
    do: where(query, [intent], intent.user_id == ^value(subject, :user_id))

  defp maybe_attempts_for_user(query, scope, _subject) when scope in ["tenant", :tenant],
    do: query

  defp maybe_attempts_for_user(query, _scope, subject),
    do: where(query, [_attempt, intent], intent.user_id == ^value(subject, :user_id))

  defp audit!(subject, action, resource_type, resource_id, metadata) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> Repo.insert!()
  end

  defp normalize_event_types(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(100)
  end

  defp normalize_event_types(nil), do: nil
  defp normalize_event_types(_), do: []

  defp normalize_attrs(attrs) do
    keys = [
      :tenant_id,
      :user_id,
      :event_type,
      :channel,
      :destination,
      :push_subscription_id,
      :push_subscription_version,
      :payload,
      :idempotency_key,
      :status,
      :next_attempt_at,
      :delivered_at
    ]

    Map.new(keys, fn key -> {key, value(attrs, key)} end) |> drop_nil()
  end

  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp conflict?(changeset, field) do
    Keyword.has_key?(changeset.errors, field) or
      Enum.any?(changeset.errors, fn {_error_field, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          metadata[:constraint_name] ==
            "notification_intents_tenant_id_idempotency_key_index"
      end)
  end

  defp payload_value(payload, key),
    do: Map.get(payload || %{}, key) || Map.get(payload || %{}, String.to_existing_atom(key))

  defp mentioned_user_ids(event) do
    case payload_value(event.payload, "mentioned_user_ids") do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp safe_text(value, _fallback) when is_binary(value), do: String.slice(value, 0, 255)
  defp safe_text(_, fallback), do: fallback
  defp safe_integer(value) when is_integer(value), do: value
  defp safe_integer(_), do: nil

  defp current_claim?(locked, claimed) do
    locked.status == :delivering and is_binary(claimed.claim_token) and
      locked.claim_token == claimed.claim_token and
      locked.claim_generation == claimed.claim_generation
  end

  defp limit(opts), do: value(opts, :limit) |> integer(50) |> min(@max_list_limit) |> max(1)
  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
