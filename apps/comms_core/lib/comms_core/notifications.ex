defmodule CommsCore.Notifications do
  import Ecto.Query

  @behaviour CommsCore.Accounts.NotificationPort

  alias CommsCore.Accounts

  alias CommsCore.Accounts.{
    AccessGrant,
    NotificationCommand,
    NotificationReceipt,
    NotificationRecipient
  }

  alias CommsCore.Audit
  alias CommsCore.Conversations
  alias CommsCore.Outbox.Event

  alias CommsCore.Notifications.{
    Attempt,
    AvailabilityNotifier,
    Delivery,
    InApp,
    Intent,
    Preference,
    Projector,
    PushSubscriptions
  }

  alias CommsCore.{Repo, RuntimePorts}

  @claim_timeout_seconds 300
  @max_list_limit 100
  @recovery_event_type "account.password_recovery.requested.v1"
  @payload_keys ~w(title body action_url conversation_id message_id sender_user_id aggregate_id aggregate_type event_id recovery_request_id)

  @impl true
  def execute(%NotificationCommand{operation: :password_recovery} = command) do
    with :ok <- require_identity_transaction(),
         {:ok, intent} <-
           create_intent(%{
             tenant_id: command.tenant_id,
             user_id: command.user_id,
             event_type: @recovery_event_type,
             channel: :email,
             destination: command.destination,
             idempotency_key: "password-recovery:#{command.recovery_request_id}",
             payload: %{"recovery_request_id" => command.recovery_request_id}
           }) do
      {:ok, %NotificationReceipt{id: intent.id}}
    end
  end

  def execute(%NotificationCommand{operation: :device_revoked} = command) do
    with :ok <- require_identity_transaction() do
      PushSubscriptions.disable_for_device(
        command.tenant_id,
        command.user_id,
        command.device_id,
        command.reason
      )
    end
  end

  def execute(%NotificationCommand{operation: :user_access_revoked} = command) do
    with :ok <- require_identity_transaction() do
      PushSubscriptions.disable_for_user(
        command.tenant_id,
        command.user_id,
        command.reason
      )
    end
  end

  def execute(%NotificationCommand{}), do: {:error, :unsupported_identity_notification_command}

  def get_preferences(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    preference =
      Repo.get_by(Preference, tenant_id: tenant_id, user_id: user_id) ||
        %Preference{
          tenant_id: tenant_id,
          user_id: user_id,
          email_enabled: true,
          push_enabled: false,
          in_app_enabled: true,
          muted_event_types: []
        }

    Projector.preference(preference)
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

    result =
      (existing || %Preference{tenant_id: tenant_id, user_id: user_id})
      |> Preference.changeset(drop_nil(changes))
      |> Repo.insert_or_update()

    project_result(result, &Projector.preference/1)
  end

  @spec list_in_app(map(), map()) ::
          {:ok,
           %{notifications: [CommsCore.Notifications.IntentView.t()], unread_count: integer()}}
          | {:error, term()}
  def list_in_app(subject, opts \\ %{}) do
    with {:ok, result} <- InApp.list(subject, opts) do
      {:ok, %{result | notifications: Enum.map(result.notifications, &Projector.intent/1)}}
    end
  end

  def unread_count(subject), do: InApp.unread_count(subject)

  def mark_in_app_read(id, subject) do
    InApp.mark_read(id, subject) |> project_result(&Projector.intent/1)
  end

  def dismiss_in_app(id, subject) do
    InApp.dismiss(id, subject) |> project_result(&Projector.intent/1)
  end

  def mark_all_in_app_read(subject), do: InApp.mark_all_read(subject)

  def push_status, do: PushSubscriptions.status()
  def push_config(subject), do: PushSubscriptions.config(subject)

  def list_push_subscriptions(subject) do
    with {:ok, subscriptions} <- PushSubscriptions.list(subject) do
      {:ok, Enum.map(subscriptions, &Projector.push_subscription/1)}
    end
  end

  def register_push_subscription(attrs, subject) do
    with {:ok, %{subscription: subscription} = result} <-
           PushSubscriptions.register(attrs, subject) do
      {:ok, %{result | subscription: Projector.push_subscription(subscription)}}
    end
  end

  def revoke_push_subscription(id, subject) do
    PushSubscriptions.revoke(id, subject) |> project_result(&Projector.push_subscription/1)
  end

  def materialize_push_destination(subscription_id, version, tenant_id),
    do: PushSubscriptions.materialize_destination(subscription_id, version, tenant_id)

  def record_push_provider_result(subscription_id, version, result),
    do: PushSubscriptions.record_provider_result(subscription_id, version, result)

  defp require_identity_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :transaction_required}
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

      {:ok, query |> Repo.all() |> Enum.map(&Projector.intent/1)}
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
          limit: ^limit
        )
        |> maybe_attempts_for_user(scope, subject)

      {:ok, query |> Repo.all() |> Enum.map(&Projector.attempt/1)}
    end
  end

  def enqueue_for_event(%Event{event_type: "message.created.v1"} = event) do
    sender_user_id = payload_value(event.payload, "sender_user_id")
    conversation_id = payload_value(event.payload, "conversation_id")

    excluded_user_ids =
      [sender_user_id | mentioned_user_ids(event)]
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    recipient_ids =
      event.tenant_id
      |> Conversations.active_member_ids(conversation_id)
      |> Enum.reject(&MapSet.member?(excluded_user_ids, &1))

    enqueue_recipient_events(event, recipient_ids)
  end

  def enqueue_for_event(%Event{event_type: "mention.created.v1"} = event) do
    conversation_id = payload_value(event.payload, "conversation_id")
    sender_user_id = payload_value(event.payload, "sender_user_id")

    mentioned_user_ids =
      event
      |> mentioned_user_ids()
      |> Enum.reject(&(&1 == sender_user_id))
      |> MapSet.new()

    recipient_ids =
      event.tenant_id
      |> Conversations.active_member_ids(conversation_id)
      |> Enum.filter(&MapSet.member?(mentioned_user_ids, &1))

    enqueue_recipient_events(event, recipient_ids)
  end

  def enqueue_for_event(%Event{}), do: :ok

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

          with :ok <- maybe_enqueue_intent(intent), do: {:ok, Projector.intent(intent)}
        else
          {:error, changeset}
        end

      {:ok, %Intent{} = intent} ->
        with :ok <- enqueue_job(intent), do: {:ok, Projector.intent(intent)}
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
    |> project_claim_result()
  end

  def record_delivery(%Delivery{} = intent, result) do
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
    |> project_result(&Projector.intent/1)
  end

  def retry_intent(id, subject) do
    with :ok <- authorize_delivery_management(subject) do
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
      |> project_result(&Projector.intent/1)
    end
  end

  defp enqueue_recipient_events(%Event{} = event, user_ids) do
    recipients = Accounts.resolve_notification_recipients(event.tenant_id, user_ids)
    preferences = preferences_by_user_id(event.tenant_id, recipients)

    Enum.reduce_while(recipients, :ok, fn recipient, :ok ->
      case enqueue_recipient_event(event, recipient, Map.get(preferences, recipient.user_id)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp preferences_by_user_id(_tenant_id, []), do: %{}

  defp preferences_by_user_id(tenant_id, recipients) do
    recipient_ids = Enum.map(recipients, & &1.user_id)

    Repo.all(
      from(preference in Preference,
        where: preference.tenant_id == ^tenant_id and preference.user_id in ^recipient_ids
      )
    )
    |> Map.new(&{&1.user_id, &1})
  end

  defp enqueue_recipient_event(
         %Event{} = event,
         %NotificationRecipient{} = recipient,
         preference
       ) do
    muted = preference && event.event_type in preference.muted_event_types

    if muted do
      :ok
    else
      with :ok <- maybe_create_in_app(event, recipient, preference),
           :ok <- maybe_create_email(event, recipient, preference),
           :ok <- maybe_create_push(event, recipient, preference) do
        :ok
      end
    end
  end

  defp maybe_create_in_app(event, recipient, preference) do
    if is_nil(preference) or preference.in_app_enabled do
      now = now()

      attrs = base_intent_attrs(event, recipient, :in_app, recipient.user_id)
      attrs = Map.merge(attrs, %{status: :delivered, delivered_at: now, next_attempt_at: now})

      # A prior availability signal can fail after the durable intent is inserted.
      # Re-signaling the idempotent intent lets the outbox retry reconcile safely.
      case create_intent_without_job(attrs) do
        {:ok, intent, status} when status in [:created, :duplicate] ->
          intent
          |> Projector.availability()
          |> AvailabilityNotifier.notify()

        {:error, _} = error ->
          error
      end
    else
      :ok
    end
  end

  defp maybe_create_email(event, recipient, preference) do
    if is_nil(preference) or preference.email_enabled do
      case create_intent(base_intent_attrs(event, recipient, :email, recipient.email)) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp maybe_create_push(event, recipient, %Preference{push_enabled: true}) do
    event.tenant_id
    |> PushSubscriptions.active_subscription_ids(recipient.user_id)
    |> Enum.reduce_while(:ok, fn subscription, :ok ->
      attrs =
        event
        |> base_intent_attrs(recipient, :push, subscription.id, subscription.id)
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

  defp maybe_create_push(_event, _recipient, _preference), do: :ok

  defp base_intent_attrs(event, recipient, channel, destination, idempotency_target \\ nil) do
    {title, body} = notification_copy(event.event_type)
    target_suffix = if is_binary(idempotency_target), do: ":#{idempotency_target}", else: ""

    %{
      tenant_id: event.tenant_id,
      user_id: recipient.user_id,
      event_type: event.event_type,
      channel: channel,
      destination: destination,
      idempotency_key: "outbox:#{event.id}:user:#{recipient.user_id}:#{channel}#{target_suffix}",
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

  defp enqueue_job(%Intent{channel: :in_app}), do: :ok

  defp enqueue_job(%Intent{} = intent) do
    %{
      "intent_id" => intent.id,
      "tenant_id" => intent.tenant_id,
      "dispatch_generation" => intent.claim_generation
    }
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:notification_delivery),
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

  @doc false
  @spec authorize_delivery_management(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_delivery_management(subject),
    do:
      authorize_tenant_role(
        subject,
        :manage_notification_delivery,
        [:owner, :admin],
        true
      )

  @doc false
  @spec authorize_tenant_scope(map()) :: :ok | {:error, :forbidden}
  def authorize_tenant_scope(subject),
    do:
      authorize_tenant_role(
        subject,
        :read_tenant_notifications,
        [:owner, :admin],
        false
      )

  defp authorize_scope("tenant", subject), do: authorize_tenant_scope(subject)

  defp authorize_scope(:tenant, subject), do: authorize_scope("tenant", subject)
  defp authorize_scope(_, _subject), do: :ok

  defp authorize_tenant_role(subject, action, roles, require_step_up?) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{} = grant} ->
        cond do
          grant.role not in roles ->
            Accounts.audit_authorization_denial(action, subject, :forbidden)

          require_step_up? and not grant.step_up_recent? ->
            Accounts.audit_authorization_denial(action, subject, :step_up_required)

          true ->
            :ok
        end

      {:error, _reason} ->
        Accounts.audit_authorization_denial(action, subject, :forbidden)
    end
  end

  defp maybe_for_user(query, scope, _subject) when scope in ["tenant", :tenant], do: query

  defp maybe_for_user(query, _scope, subject),
    do: where(query, [intent], intent.user_id == ^value(subject, :user_id))

  defp maybe_attempts_for_user(query, scope, _subject) when scope in ["tenant", :tenant],
    do: query

  defp maybe_attempts_for_user(query, _scope, subject),
    do: where(query, [_attempt, intent], intent.user_id == ^value(subject, :user_id))

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
  defp project_result({:ok, value}, projector), do: {:ok, projector.(value)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp project_claim_result({:ok, {:already_delivered, intent}}),
    do: {:ok, {:already_delivered, Projector.intent(intent)}}

  defp project_claim_result({:ok, intent}), do: {:ok, Projector.delivery(intent)}
  defp project_claim_result({:error, _reason} = error), do: error

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
