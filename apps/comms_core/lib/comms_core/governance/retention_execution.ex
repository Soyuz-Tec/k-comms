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

  def enqueue_due_retention(tenant_id, caller) when is_binary(tenant_id) do
    if RuntimePorts.authorized_job_worker?(:retention, caller) do
      case Accounts.retention_actor_id(tenant_id) do
        {:ok, owner_id} ->
          due = due_retention_messages(tenant_id, 100)

          enqueued =
            Enum.count(due, fn candidate ->
              enqueue_retention_deletion(owner_id, candidate)
            end)

          {:ok, %{enqueued: enqueued, scanned: length(due), has_more: length(due) == 100}}

        {:error, :last_owner_required} = error ->
          error
      end
    else
      {:error, :forbidden}
    end
  end

  def enqueue_due_retention(_tenant_id, _caller), do: {:error, :forbidden}

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

  defp due_retention_messages(tenant_id, limit) do
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

    excluded_message_ids =
      Repo.all(
        from(r in DeletionRequest,
          where:
            r.tenant_id == ^tenant_id and r.target_type == :message and
              r.status in [:pending, :approved, :in_progress, :completed],
          select: r.message_id
        )
      )
      |> Enum.reject(&is_nil/1)

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

    tenant_id
    |> Messaging.retention_candidates(scopes, excluded_message_ids, limit)
    |> Enum.map(fn %RetentionCandidate{} = candidate ->
      metadata = Map.fetch!(metadata_by_conversation_id, candidate.conversation_id)

      %{
        tenant_id: tenant_id,
        message_id: candidate.message_id,
        policy_id: metadata.policy_id,
        delete_attachments: metadata.delete_attachments
      }
    end)
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
      {:ok, enqueued?} -> enqueued?
      {:error, _reason} -> false
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
