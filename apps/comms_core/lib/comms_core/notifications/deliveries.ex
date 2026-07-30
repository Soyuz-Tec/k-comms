defmodule CommsCore.Notifications.Deliveries do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Audit

  alias CommsCore.Notifications.{
    Attempt,
    Delivery,
    Intent,
    Intents,
    Policy,
    Projector
  }

  alias CommsCore.Repo

  @claim_timeout_seconds 300
  @max_list_limit 100
  @recovery_event_type "account.password_recovery.requested.v1"

  def list_attempts(subject, opts \\ %{}) do
    limit = limit(opts)
    scope = value(opts, :scope)
    tenant_id = value(subject, :tenant_id)

    with :ok <- Policy.authorize_scope(scope, subject) do
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

  def claim(id) when is_binary(id) do
    Repo.transaction(fn ->
      intent = Repo.one(from(intent in Intent, where: intent.id == ^id, lock: "FOR UPDATE"))

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

  def record(%Delivery{} = delivery, result) do
    Repo.transaction(fn ->
      locked =
        Repo.one!(from(intent in Intent, where: intent.id == ^delivery.id, lock: "FOR UPDATE"))

      unless current_claim?(locked, delivery) do
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

  def retry(id, subject) do
    with :ok <- Policy.authorize_delivery_management(subject) do
      Repo.transaction(fn ->
        intent =
          Repo.one(
            from(intent in Intent,
              where:
                intent.id == ^id and intent.tenant_id == ^value(subject, :tenant_id) and
                  intent.event_type != @recovery_event_type,
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

        case Intents.enqueue_job(updated) do
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

  defp maybe_attempts_for_user(query, scope, _subject) when scope in ["tenant", :tenant],
    do: query

  defp maybe_attempts_for_user(query, _scope, subject),
    do: where(query, [_attempt, intent], intent.user_id == ^value(subject, :user_id))

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
  defp safe_text(value, _fallback) when is_binary(value), do: String.slice(value, 0, 255)
  defp safe_text(_, fallback), do: fallback
  defp safe_integer(value) when is_integer(value), do: value
  defp safe_integer(_), do: nil
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
