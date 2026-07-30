defmodule CommsCore.Governance.PolicyManagement do
  @moduledoc false

  import Ecto.Query
  import CommsCore.Governance.Support

  alias CommsCore.Administration.RetentionDefaults
  alias CommsCore.Audit

  alias CommsCore.Governance.{
    Authorization,
    DeletionRequest,
    DeletionWorkflow,
    LegalHold,
    RetentionDefaultsReader,
    RetentionPolicy,
    TenantLock
  }

  alias CommsCore.Messaging.{RetentionCandidate, RetentionScope}
  alias CommsCore.{Accounts, Conversations, Messaging, Repo, RuntimePorts}

  def create_retention_policy(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- Authorization.authorize(subject),
         :ok <- validate_conversation(tenant_id, value(attrs, :conversation_id)) do
      case existing_idempotent(RetentionPolicy, tenant_id, idempotency_key) do
        %RetentionPolicy{} = policy ->
          {:ok, %{policy: policy, replayed: true}}

        nil ->
          case insert_retention_policy(attrs, subject) do
            {:ok, result} = success ->
              enqueue_retention_scan(result.policy.tenant_id)
              success

            {:error, _} = error ->
              error
          end
      end
    end
  end

  def list_retention_policies(params, subject) do
    with :ok <- Authorization.authorize(subject) do
      query =
        RetentionPolicy
        |> where([p], p.tenant_id == ^value(subject, :tenant_id))
        |> maybe_equal(:status, enum(value(params, :status), [:active, :disabled]))
        |> maybe_equal(:scope_type, enum(value(params, :scope_type), [:tenant, :conversation]))
        |> order_by([p], asc: p.name)
        |> limit(^parse_limit(value(params, :limit)))

      {:ok, Repo.all(query)}
    end
  end

  def update_retention_policy(id, attrs, subject) do
    with :ok <- Authorization.authorize(subject),
         {:ok, expected_version} <- expected_version(attrs),
         :ok <- require_reason_for_change(attrs, :status, :reason),
         :ok <- validate_conversation(value(subject, :tenant_id), value(attrs, :conversation_id)) do
      result =
        update_versioned(
          RetentionPolicy,
          id,
          expected_version,
          attrs,
          subject,
          &RetentionPolicy.changeset/2,
          [:name, :scope_type, :conversation_id, :retention_days, :delete_attachments, :status],
          "retention_policy.update"
        )

      case result do
        {:ok, policy} = success ->
          enqueue_retention_scan(policy.tenant_id)
          success

        {:error, _} = error ->
          error
      end
    end
  end

  def create_legal_hold(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- Authorization.authorize(subject),
         :ok <- validate_hold_target(attrs, tenant_id) do
      Repo.transaction(fn ->
        TenantLock.lock!(tenant_id)

        if Repo.exists?(
             from(r in DeletionRequest,
               where: r.tenant_id == ^tenant_id and r.status == :in_progress
             )
           ),
           do: Repo.rollback(:deletion_in_progress)

        case existing_idempotent(LegalHold, tenant_id, idempotency_key) do
          %LegalHold{} = hold ->
            %{hold: hold, replayed: true}

          nil ->
            id = Ecto.UUID.generate()

            hold =
              %LegalHold{id: id}
              |> LegalHold.changeset(%{
                tenant_id: tenant_id,
                created_by_user_id: value(subject, :user_id),
                subject_user_id: value(attrs, :subject_user_id),
                conversation_id: value(attrs, :conversation_id),
                name: value(attrs, :name),
                reason: value(attrs, :reason),
                scope_type: value(attrs, :scope_type),
                status: :active,
                starts_at: now(),
                idempotency_key: idempotency_key
              })
              |> insert_or_rollback()

            audit!(subject, "legal_hold.create", "legal_hold", hold.id, %{
              scope_type: hold.scope_type
            })

            %{hold: hold, replayed: false}
        end
      end)
      |> transaction_result()
    end
  end

  def list_legal_holds(params, subject) do
    with :ok <- Authorization.authorize(subject) do
      query =
        LegalHold
        |> where([h], h.tenant_id == ^value(subject, :tenant_id))
        |> maybe_equal(:status, enum(value(params, :status), [:active, :released]))
        |> maybe_equal(
          :scope_type,
          enum(value(params, :scope_type), [:tenant, :user, :conversation])
        )
        |> order_by([h], desc: h.inserted_at)
        |> limit(^parse_limit(value(params, :limit)))

      {:ok, Repo.all(query)}
    end
  end

  def release_legal_hold(id, attrs, subject) do
    with :ok <- Authorization.authorize(subject),
         {:ok, expected_version} <- expected_version(attrs),
         :ok <- require_reason(value(attrs, :release_reason)) do
      Repo.transaction(fn ->
        hold = lock_record!(LegalHold, id, subject)
        verify_version!(hold, expected_version)
        if hold.status != :active, do: Repo.rollback(:legal_hold_not_active)

        updated =
          hold
          |> LegalHold.changeset(%{status: :released, released_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        audit!(subject, "legal_hold.release", "legal_hold", hold.id, %{
          version: updated.lock_version,
          reason: value(attrs, :release_reason)
        })

        updated
      end)
      |> transaction_result()
    end
  end

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

  defp insert_retention_policy(attrs, subject) do
    id = Ecto.UUID.generate()

    changes = %{
      tenant_id: value(subject, :tenant_id),
      conversation_id: value(attrs, :conversation_id),
      name: value(attrs, :name),
      scope_type: value(attrs, :scope_type) || :tenant,
      retention_days: value(attrs, :retention_days),
      delete_attachments: default(value(attrs, :delete_attachments), true),
      status: value(attrs, :status) || :active,
      idempotency_key: value(attrs, :idempotency_key)
    }

    insert_with_audit(
      :policy,
      RetentionPolicy.changeset(%RetentionPolicy{id: id}, changes),
      subject,
      "retention_policy.create",
      "retention_policy",
      id,
      %{scope_type: changes.scope_type, retention_days: changes.retention_days}
    )
  end

  defp validate_conversation(_tenant_id, nil), do: :ok

  defp validate_conversation(tenant_id, id) do
    tenant_id
    |> Conversations.validate_reference(id)
    |> governance_target_result()
  end

  defp validate_hold_target(attrs, tenant_id) do
    case enum(value(attrs, :scope_type), [:tenant, :user, :conversation]) do
      :tenant ->
        if is_nil(value(attrs, :subject_user_id)) and is_nil(value(attrs, :conversation_id)),
          do: :ok,
          else: {:error, :invalid_governance_target}

      :user ->
        tenant_id
        |> Accounts.validate_governance_user(value(attrs, :subject_user_id))
        |> governance_target_result()

      :conversation ->
        validate_conversation(tenant_id, value(attrs, :conversation_id))

      nil ->
        {:error, :invalid_governance_target}
    end
  end

  defp enqueue_retention_scan(tenant_id, scheduled_in \\ 0) do
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
    |> Repo.insert()
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

  defp insert_with_audit(key, changeset, subject, action, resource_type, id, metadata) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(key, changeset)
    |> Audit.append(audit_command(subject, action, resource_type, id, metadata))
    |> Repo.transaction()
    |> case do
      {:ok, result} -> {:ok, %{key => Map.fetch!(result, key), replayed: false}}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp update_versioned(
         schema,
         id,
         expected_version,
         attrs,
         subject,
         changeset_fn,
         fields,
         action
       ) do
    Repo.transaction(fn ->
      record = lock_record!(schema, id, subject)
      verify_version!(record, expected_version)

      changes =
        Enum.reduce(fields, %{}, fn field, acc ->
          case fetch_value(attrs, field) do
            {:ok, value} -> Map.put(acc, field, value)
            :error -> acc
          end
        end)

      updated =
        record
        |> changeset_fn.(changes)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

      audit_metadata = %{
        version: updated.lock_version,
        changed_fields: Map.keys(changes)
      }

      audit_metadata =
        case value(attrs, :reason) do
          reason when is_binary(reason) -> Map.put(audit_metadata, :reason, String.trim(reason))
          _ -> audit_metadata
        end

      audit!(subject, action, "retention_policy", record.id, audit_metadata)

      updated
    end)
    |> transaction_result()
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
