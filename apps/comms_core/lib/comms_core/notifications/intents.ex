defmodule CommsCore.Notifications.Intents do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Notifications.{Intent, Policy, Projector}
  alias CommsCore.{Repo, RuntimePorts}

  @max_list_limit 100
  @recovery_event_type "account.password_recovery.requested.v1"
  @payload_keys ~w(title body action_url conversation_id message_id sender_user_id aggregate_id aggregate_type event_id recovery_request_id)

  def list(subject, opts \\ %{}) do
    limit = limit(opts)
    scope = value(opts, :scope)
    tenant_id = value(subject, :tenant_id)

    with :ok <- Policy.authorize_scope(scope, subject) do
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

  def create(attrs) when is_map(attrs) do
    attrs = normalize_for_insert(attrs)
    changeset = Intent.changeset(%Intent{}, attrs)

    case Repo.insert(changeset) do
      {:error, changeset} when is_map(changeset) ->
        if conflict?(changeset, :idempotency_key) do
          intent =
            Repo.get_by!(Intent,
              tenant_id: Map.fetch!(attrs, :tenant_id),
              idempotency_key: Map.fetch!(attrs, :idempotency_key)
            )

          with :ok <- maybe_enqueue(intent), do: {:ok, Projector.intent(intent)}
        else
          {:error, changeset}
        end

      {:ok, %Intent{} = intent} ->
        with :ok <- enqueue_job(intent), do: {:ok, Projector.intent(intent)}
    end
  end

  def create_without_job(attrs) when is_map(attrs) do
    attrs = normalize_for_insert(attrs)
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

  def enqueue_job(%Intent{channel: :in_app}), do: :ok

  def enqueue_job(%Intent{} = intent) do
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

  defp normalize_for_insert(attrs) do
    attrs
    |> normalize_attrs()
    |> sanitize_intent_payload()
    |> Map.put_new(:next_attempt_at, now())
    |> Map.put_new(:status, :pending)
  end

  defp maybe_enqueue(%Intent{status: :delivered}), do: :ok
  defp maybe_enqueue(intent), do: enqueue_job(intent)

  defp sanitize_payload(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, val}, acc ->
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

  defp maybe_for_user(query, scope, _subject) when scope in ["tenant", :tenant], do: query

  defp maybe_for_user(query, _scope, subject),
    do: where(query, [intent], intent.user_id == ^value(subject, :user_id))

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

  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp limit(opts), do: value(opts, :limit) |> integer(50) |> min(@max_list_limit) |> max(1)
  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
