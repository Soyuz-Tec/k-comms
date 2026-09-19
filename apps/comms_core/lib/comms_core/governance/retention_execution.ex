defmodule CommsCore.Governance.RetentionExecution do
  @moduledoc false

  import Ecto.Query
  import CommsCore.Governance.Support

  alias CommsCore.Administration.RetentionDefaults

  alias CommsCore.Governance.{
    DeletionRequest,
    DeletionWorkflow,
    RetentionDefaultsReader,
    RetentionPolicy
  }

  alias CommsCore.Messaging.{RetentionCandidate, RetentionScope}
  alias CommsCore.{Accounts, Conversations, Messaging, Repo, RuntimePorts}

  def enqueue_due_retention(tenant_id, caller), do: enqueue_due_retention(tenant_id, caller, nil)

  def enqueue_due_retention(tenant_id, caller, cursor) when is_binary(tenant_id) do
    if RuntimePorts.authorized_job_worker?(:retention, caller) do
      with :ok <- validate_cursor(cursor),
           {:ok, owner_id} <- Accounts.retention_actor_id(tenant_id) do
        {due, scanned, next_cursor} = due_retention_messages(tenant_id, 100, cursor)

        with {:ok, enqueued} <- enqueue_candidates(owner_id, due) do
          {:ok,
           %{
             enqueued: enqueued,
             scanned: scanned,
             has_more: scanned == 100,
             next_cursor: next_cursor
           }}
        end
      end
    else
      {:error, :forbidden}
    end
  end

  def enqueue_due_retention(_tenant_id, _caller, _cursor), do: {:error, :forbidden}

  defp validate_cursor(nil), do: :ok

  defp validate_cursor(%{"inserted_at" => timestamp, "message_id" => id})
       when is_binary(timestamp) and is_binary(id) do
    with {:ok, _, _} <- DateTime.from_iso8601(timestamp),
         {:ok, _} <- Ecto.UUID.cast(id) do
      :ok
    else
      _ -> {:error, :invalid_retention_cursor}
    end
  end

  defp validate_cursor(_), do: {:error, :invalid_retention_cursor}

  def enqueue_retention_scan(tenant_id, scheduled_in, insert_retention_job) do
    options =
      [
        worker: RuntimePorts.job_worker_name!(:retention),
        queue: :default,
        unique: [
          period: 300,
          fields: [:worker, :args],
          states: [:available, :scheduled, :retryable]
        ]
      ]
      |> then(fn options ->
        if scheduled_in > 0, do: Keyword.put(options, :scheduled_in, scheduled_in), else: options
      end)

    %{"tenant_id" => tenant_id}
    |> Oban.Job.new(options)
    |> insert_retention_job.()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp due_retention_messages(tenant_id, limit, cursor) do
    policies =
      Repo.all(
        from(p in RetentionPolicy,
          where: p.tenant_id == ^tenant_id and p.status == :active
        )
      )

    tenant_policy = Enum.find(policies, &(&1.scope_type == :tenant))
    conversation_policies = Map.new(policies, &{&1.conversation_id, &1})

    %RetentionDefaults{default_retention_days: configured_default_days} =
      RetentionDefaultsReader.fetch(tenant_id)
      |> owner_command_or_rollback()

    default_days =
      if tenant_policy,
        do: tenant_policy.retention_days,
        else: configured_default_days

    scan_started_at = now()

    {scopes, metadata_by_conversation_id} =
      tenant_id
      |> Conversations.retention_scope_ids()
      |> Enum.reduce({[], %{}}, fn conversation_id, {scopes, metadata} ->
        policy = Map.get(conversation_policies, conversation_id) || tenant_policy
        days = if policy, do: policy.retention_days, else: default_days

        if is_integer(days) and days > 0 do
          scope = %RetentionScope{
            conversation_id: conversation_id,
            cutoff_at: DateTime.add(scan_started_at, -days * 86_400, :second)
          }

          retention_metadata = %{
            policy_id: policy && policy.id,
            delete_attachments: if(policy, do: policy.delete_attachments, else: true)
          }

          {[scope | scopes], Map.put(metadata, conversation_id, retention_metadata)}
        else
          {scopes, metadata}
        end
      end)

    candidates = Messaging.retention_candidates(tenant_id, scopes, [], limit, cursor)
    candidate_ids = Enum.map(candidates, & &1.message_id)

    excluded_ids =
      Repo.all(
        from(r in DeletionRequest,
          where:
            r.tenant_id == ^tenant_id and r.target_type == :message and
              r.message_id in ^candidate_ids and
              r.status in [:pending, :approved, :in_progress, :completed],
          select: r.message_id
        )
      )
      |> MapSet.new()

    due =
      candidates
      |> Enum.reject(&MapSet.member?(excluded_ids, &1.message_id))
      |> Enum.map(fn %RetentionCandidate{} = candidate ->
        metadata = Map.fetch!(metadata_by_conversation_id, candidate.conversation_id)

        %{
          tenant_id: tenant_id,
          message_id: candidate.message_id,
          policy_id: metadata.policy_id,
          delete_attachments: metadata.delete_attachments
        }
      end)

    next_cursor =
      case List.last(candidates) do
        nil ->
          nil

        candidate ->
          %{
            "inserted_at" => DateTime.to_iso8601(candidate.inserted_at),
            "message_id" => candidate.message_id
          }
      end

    {due, length(candidates), next_cursor}
  end

  defp enqueue_retention_deletion(owner_id, candidate) do
    idempotency_key = "retention:#{candidate.message_id}"

    case Repo.transaction(fn ->
           existing =
             Repo.get_by(DeletionRequest,
               tenant_id: candidate.tenant_id,
               idempotency_key: idempotency_key
             )

           if existing do
             false
           else
             id = Ecto.UUID.generate()

             request =
               %DeletionRequest{id: id}
               |> DeletionRequest.changeset(%{
                 tenant_id: candidate.tenant_id,
                 requested_by_user_id: owner_id,
                 message_id: candidate.message_id,
                 target_type: :message,
                 reason: "Retention policy expiration",
                 status: :approved,
                 scheduled_for: now(),
                 evidence: %{
                   retention_policy_id: candidate.policy_id,
                   retention_delete_attachments: candidate.delete_attachments
                 },
                 idempotency_key: idempotency_key
               })
               |> insert_or_rollback()

             audit_system!(candidate.tenant_id, "retention.deletion_enqueued", request.id, %{
               message_id: candidate.message_id,
               policy_id: candidate.policy_id
             })

             DeletionWorkflow.enqueue_deletion!(request)
             true
           end
         end) do
      {:ok, enqueued?} -> {:ok, enqueued?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_candidates(owner_id, candidates) do
    Enum.reduce_while(candidates, {:ok, 0}, fn candidate, {:ok, count} ->
      case enqueue_retention_deletion(owner_id, candidate) do
        {:ok, true} -> {:cont, {:ok, count + 1}}
        {:ok, false} -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
