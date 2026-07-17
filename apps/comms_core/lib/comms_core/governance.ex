defmodule CommsCore.Governance do
  import Ecto.Query

  alias CommsCore.Accounts.{AccessGrant, User}
  alias CommsCore.Administration.RetentionDefaults
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Audit
  alias CommsCore.Conversations.Conversation

  alias CommsCore.Governance.{
    DeletionExecution,
    DeletionRequest,
    LegalHold,
    RetentionDefaultsReader,
    RetentionPolicy
  }

  alias CommsCore.Messaging.Message
  alias CommsCore.Messaging.MessageDeletionCandidate

  alias CommsCore.{
    Accounts,
    Attachments,
    AudioCalls,
    Conversations,
    Messaging,
    Repo,
    RuntimePorts
  }

  @doc false
  def authorize_governance(subject) when is_map(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{} = grant} ->
        cond do
          grant.role not in [:owner, :compliance_admin] ->
            Accounts.audit_authorization_denial(:govern_tenant, subject, :forbidden)

          not grant.step_up_recent? ->
            Accounts.audit_authorization_denial(
              :govern_tenant,
              subject,
              :step_up_required
            )

          true ->
            :ok
        end

      {:error, _reason} ->
        Accounts.audit_authorization_denial(:govern_tenant, subject, :forbidden)
    end
  end

  def authorize_governance(_subject), do: {:error, :forbidden}

  @max_limit 100

  def create_retention_policy_view(attrs, subject) do
    with {:ok, result} <- create_retention_policy(attrs, subject) do
      {:ok, %{result | policy: CommsCore.Governance.Projector.retention_policy(result.policy)}}
    end
  end

  def list_retention_policy_views(params, subject) do
    with {:ok, policies} <- list_retention_policies(params, subject) do
      {:ok, Enum.map(policies, &CommsCore.Governance.Projector.retention_policy/1)}
    end
  end

  def update_retention_policy_view(id, attrs, subject),
    do:
      update_retention_policy(id, attrs, subject)
      |> project_result(&CommsCore.Governance.Projector.retention_policy/1)

  def create_legal_hold_view(attrs, subject) do
    with {:ok, result} <- create_legal_hold(attrs, subject) do
      {:ok, %{result | hold: CommsCore.Governance.Projector.legal_hold(result.hold)}}
    end
  end

  def list_legal_hold_views(params, subject) do
    with {:ok, holds} <- list_legal_holds(params, subject) do
      {:ok, Enum.map(holds, &CommsCore.Governance.Projector.legal_hold/1)}
    end
  end

  def release_legal_hold_view(id, attrs, subject),
    do:
      release_legal_hold(id, attrs, subject)
      |> project_result(&CommsCore.Governance.Projector.legal_hold/1)

  def create_deletion_request_view(attrs, subject) do
    with {:ok, result} <- create_deletion_request(attrs, subject) do
      {:ok, %{result | request: CommsCore.Governance.Projector.deletion_request(result.request)}}
    end
  end

  def list_deletion_request_views(params, subject) do
    with {:ok, requests} <- list_deletion_requests(params, subject) do
      {:ok, Enum.map(requests, &CommsCore.Governance.Projector.deletion_request/1)}
    end
  end

  def transition_deletion_request_view(id, attrs, subject),
    do:
      transition_deletion_request(id, attrs, subject)
      |> project_result(&CommsCore.Governance.Projector.deletion_request/1)

  @doc """
  Coordinates an IdentityAccess user-lifecycle change with Governance policy.

  Approved and in-progress deletion requests are reduced to user identifiers
  and supplied to the IdentityAccess owner command in the same transaction.
  """
  def change_user_lifecycle_view(user_id, attrs, subject)
      when is_binary(user_id) and is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- Accounts.preflight_user_lifecycle_change(user_id, attrs, subject) do
      Repo.transaction(fn ->
        governance_lock!(tenant_id)

        Accounts.apply_user_lifecycle_change(
          user_id,
          attrs,
          subject,
          pending_deletion_user_ids(tenant_id)
        )
        |> owner_command_or_rollback()
      end)
      |> transaction_result()
    end
  end

  def change_user_lifecycle_view(_user_id, _attrs, _subject), do: {:error, :not_found}

  def delete_message(message_id, subject) when is_binary(message_id) and is_map(subject) do
    Repo.transaction(fn ->
      case Messaging.delete_message(message_id, subject, &authorize_message_deletion/1) do
        {:ok, message} -> message
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  def delete_message(_message_id, _subject), do: {:error, :not_found}

  defp authorize_message_deletion(%MessageDeletionCandidate{} = candidate) do
    governance_lock!(candidate.tenant_id)

    if active_legal_hold?(
         candidate.tenant_id,
         [candidate.conversation_id],
         [candidate.sender_user_id]
       ) do
      {:error, :legal_hold_active}
    else
      :ok
    end
  end

  def create_retention_policy(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- authorize_governance(subject),
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
    with :ok <- authorize_governance(subject) do
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
    with :ok <- authorize_governance(subject),
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

    with :ok <- authorize_governance(subject),
         :ok <- validate_hold_target(attrs, tenant_id) do
      Repo.transaction(fn ->
        governance_lock!(tenant_id)

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
    with :ok <- authorize_governance(subject) do
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
    with :ok <- authorize_governance(subject),
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

  def create_deletion_request(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- authorize_governance(subject),
         :ok <- validate_deletion_target(attrs, tenant_id) do
      case existing_idempotent(DeletionRequest, tenant_id, idempotency_key) do
        %DeletionRequest{} = request -> {:ok, %{request: request, replayed: true}}
        nil -> insert_deletion_request(attrs, subject)
      end
    end
  end

  def list_deletion_requests(params, subject) do
    with :ok <- authorize_governance(subject) do
      statuses = [:pending, :approved, :in_progress, :completed, :rejected, :cancelled]

      query =
        DeletionRequest
        |> where([r], r.tenant_id == ^value(subject, :tenant_id))
        |> maybe_equal(:status, enum(value(params, :status), statuses))
        |> maybe_equal(
          :target_type,
          enum(value(params, :target_type), [:user, :conversation, :message])
        )
        |> order_by([r], desc: r.inserted_at)
        |> limit(^parse_limit(value(params, :limit)))

      {:ok, Repo.all(query)}
    end
  end

  def transition_deletion_request(id, attrs, subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- authorize_governance(subject),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, status} <- administrative_deletion_status(value(attrs, :status)),
         :ok <- require_reason(value(attrs, :transition_reason)) do
      Repo.transaction(fn ->
        governance_lock!(tenant_id)

        authorize_governance(subject)
        |> authorization_or_rollback!()

        request = lock_record!(DeletionRequest, id, subject)
        verify_version!(request, expected_version)
        validate_deletion_transition!(request.status, status)
        if status == :approved, do: ensure_deletion_preconditions!(request)

        updated =
          request
          |> DeletionRequest.changeset(%{
            status: status,
            scheduled_for: value(attrs, :scheduled_for) || request.scheduled_for,
            evidence: request.evidence || %{}
          })
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        if status == :approved, do: enqueue_deletion!(updated)

        audit!(subject, "deletion_request.#{status}", "deletion_request", request.id, %{
          before_status: request.status,
          status: status,
          version: updated.lock_version,
          reason: value(attrs, :transition_reason)
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def claim_deletion_request(id, caller) do
    if RuntimePorts.authorized_job_worker?(:deletion, caller) do
      Repo.transaction(fn ->
        request = lock_deletion_request_for_worker!(id)

        if request.status not in [:approved, :in_progress], do: Repo.rollback(:not_claimable)
        if legal_hold_blocks?(request), do: Repo.rollback(:legal_hold_active)
        ensure_deletion_preconditions!(request)

        claimed =
          request
          |> DeletionRequest.changeset(%{
            status: :in_progress,
            execution_started_at: request.execution_started_at || now(),
            execution_attempts: request.execution_attempts + 1,
            execution_error: nil
          })
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        audit_system!(claimed.tenant_id, "deletion_request.claim", claimed.id, %{
          attempt: claimed.execution_attempts,
          version: claimed.lock_version
        })

        plan = deletion_plan(claimed)

        struct!(DeletionExecution, %{
          request_id: claimed.id,
          expected_version: claimed.lock_version,
          objects: plan.attachments
        })
      end)
      |> transaction_result()
    else
      {:error, :forbidden}
    end
  end

  def complete_deletion_request(id, expected_version, worker_evidence, caller)
      when is_map(worker_evidence) do
    if RuntimePorts.authorized_job_worker?(:deletion, caller) do
      Repo.transaction(fn ->
        request = lock_deletion_request_for_worker!(id)

        if request.status == :completed, do: Repo.rollback(:already_delivered)
        if request.status != :in_progress, do: Repo.rollback(:not_claimable)
        verify_version!(request, expected_version)
        if legal_hold_blocks?(request), do: Repo.rollback(:legal_hold_active)

        plan = deletion_plan(request)
        deleted_object_count = value(worker_evidence, :deleted_object_count)

        unless is_integer(deleted_object_count) and
                 deleted_object_count == length(plan.attachments),
               do: Repo.rollback(:deletion_evidence_mismatch)

        results = apply_deletion!(request, plan)

        evidence = %{
          executor: RuntimePorts.job_worker_name!(:deletion),
          completed_at: DateTime.to_iso8601(now()),
          target_type: request.target_type,
          messages_tombstoned: results.messages_tombstoned,
          attachments_deleted: results.attachments_deleted,
          deleted_object_count: deleted_object_count,
          target_digest: target_digest(request)
        }

        completed =
          request
          |> DeletionRequest.changeset(%{
            status: :completed,
            completed_at: now(),
            evidence: evidence,
            execution_error: nil
          })
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        audit_system!(request.tenant_id, "deletion_request.completed", request.id, %{
          version: completed.lock_version,
          evidence: evidence
        })

        %{request: completed, revoked_session_ids: results.revoked_session_ids}
      end)
      |> transaction_result()
    else
      {:error, :forbidden}
    end
  end

  def complete_deletion_request(_id, _version, _evidence, _caller),
    do: {:error, :forbidden}

  def record_deletion_failure(id, reason, caller) do
    if RuntimePorts.authorized_job_worker?(:deletion, caller) do
      safe_reason = reason |> inspect(limit: 20, printable_limit: 200) |> String.slice(0, 500)

      Repo.transaction(fn ->
        request = lock_deletion_request_for_worker!(id)

        if request.status != :in_progress, do: Repo.rollback(:not_claimable)

        updated =
          request
          |> DeletionRequest.changeset(%{execution_error: safe_reason})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        audit_system!(request.tenant_id, "deletion_request.failure", request.id, %{
          attempt: request.execution_attempts,
          error_code: "provider_failure"
        })

        updated
      end)
      |> transaction_result()
    else
      {:error, :forbidden}
    end
  end

  def enqueue_due_retention(tenant_id, caller) when is_binary(tenant_id) do
    if RuntimePorts.authorized_job_worker?(:retention, caller) do
      owner =
        Repo.one(
          from(u in User,
            where: u.tenant_id == ^tenant_id and u.role == :owner and u.status == :active,
            order_by: [asc: u.inserted_at],
            limit: 1
          )
        )

      if owner do
        due = due_retention_messages(tenant_id, 100)

        enqueued =
          Enum.count(due, fn candidate ->
            enqueue_retention_deletion(owner, candidate)
          end)

        {:ok, %{enqueued: enqueued, scanned: length(due), has_more: length(due) == 100}}
      else
        {:error, :last_owner_required}
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

  defp insert_deletion_request(attrs, subject) do
    id = Ecto.UUID.generate()

    changes = %{
      tenant_id: value(subject, :tenant_id),
      requested_by_user_id: value(subject, :user_id),
      subject_user_id: value(attrs, :subject_user_id),
      conversation_id: value(attrs, :conversation_id),
      message_id: value(attrs, :message_id),
      target_type: value(attrs, :target_type),
      reason: value(attrs, :reason),
      status: :pending,
      scheduled_for: value(attrs, :scheduled_for),
      evidence: %{},
      idempotency_key: value(attrs, :idempotency_key)
    }

    insert_with_audit(
      :request,
      DeletionRequest.changeset(%DeletionRequest{id: id}, changes),
      subject,
      "deletion_request.create",
      "deletion_request",
      id,
      %{target_type: changes.target_type}
    )
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

      audit!(subject, action, schema_resource(schema), record.id, audit_metadata)

      updated
    end)
    |> transaction_result()
  end

  defp lock_record!(schema, id, subject) do
    Repo.one(
      from(r in schema,
        where: r.id == ^id and r.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_deletion_request_for_worker!(id) do
    tenant_id =
      Repo.one(from(r in DeletionRequest, where: r.id == ^id, select: r.tenant_id)) ||
        Repo.rollback(:not_found)

    governance_lock!(tenant_id)

    Repo.one(
      from(r in DeletionRequest,
        where: r.id == ^id and r.tenant_id == ^tenant_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp verify_version!(record, expected_version) do
    if record.lock_version != expected_version, do: Repo.rollback(:stale_version)
  end

  defp validate_conversation(_tenant_id, nil), do: :ok

  defp validate_conversation(tenant_id, id) do
    if Repo.exists?(from(c in Conversation, where: c.id == ^id and c.tenant_id == ^tenant_id)),
      do: :ok,
      else: {:error, :invalid_governance_target}
  end

  defp validate_hold_target(attrs, tenant_id) do
    case enum(value(attrs, :scope_type), [:tenant, :user, :conversation]) do
      :tenant ->
        if is_nil(value(attrs, :subject_user_id)) and is_nil(value(attrs, :conversation_id)),
          do: :ok,
          else: {:error, :invalid_governance_target}

      :user ->
        if Repo.exists?(
             from(u in User,
               where: u.id == ^value(attrs, :subject_user_id) and u.tenant_id == ^tenant_id
             )
           ),
           do: :ok,
           else: {:error, :invalid_governance_target}

      :conversation ->
        validate_conversation(tenant_id, value(attrs, :conversation_id))

      nil ->
        {:error, :invalid_governance_target}
    end
  end

  defp validate_deletion_target(attrs, tenant_id) do
    case enum(value(attrs, :target_type), [:user, :conversation, :message]) do
      :user ->
        exists_target?(User, value(attrs, :subject_user_id), tenant_id)

      :conversation ->
        exists_target?(Conversation, value(attrs, :conversation_id), tenant_id)

      :message ->
        exists_target?(Message, value(attrs, :message_id), tenant_id)

      nil ->
        {:error, :invalid_governance_target}
    end
  end

  defp exists_target?(_schema, nil, _tenant_id), do: {:error, :invalid_governance_target}

  defp exists_target?(schema, id, tenant_id) do
    if Repo.exists?(from(r in schema, where: r.id == ^id and r.tenant_id == ^tenant_id)),
      do: :ok,
      else: {:error, :invalid_governance_target}
  end

  defp enqueue_deletion!(request) do
    %{"deletion_request_id" => request.id, "tenant_id" => request.tenant_id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:deletion),
      queue: :default,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Repo.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback(reason)
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

    existing_requests =
      from(r in DeletionRequest,
        where:
          r.tenant_id == ^tenant_id and r.target_type == :message and
            r.status in [:pending, :approved, :in_progress, :completed],
        select: r.message_id
      )

    conversations = Repo.all(from(c in Conversation, where: c.tenant_id == ^tenant_id))

    Enum.reduce_while(conversations, [], fn conversation, acc ->
      remaining = limit - length(acc)

      if remaining <= 0 do
        {:halt, acc}
      else
        policy = Map.get(conversation_policies, conversation.id) || tenant_policy
        days = if policy, do: policy.retention_days, else: default_days

        if is_integer(days) and days > 0 do
          cutoff = DateTime.add(now(), -days * 86_400, :second)

          candidates =
            Repo.all(
              from(m in Message,
                where:
                  m.tenant_id == ^tenant_id and m.conversation_id == ^conversation.id and
                    m.status != :deleted and m.inserted_at < ^cutoff and
                    m.id not in subquery(existing_requests),
                order_by: [asc: m.inserted_at, asc: m.id],
                limit: ^remaining,
                select: m.id
              )
            )
            |> Enum.map(fn message_id ->
              %{
                tenant_id: tenant_id,
                message_id: message_id,
                policy_id: policy && policy.id,
                delete_attachments: if(policy, do: policy.delete_attachments, else: true)
              }
            end)

          {:cont, acc ++ candidates}
        else
          {:cont, acc}
        end
      end
    end)
  end

  defp enqueue_retention_deletion(owner, candidate) do
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
                 requested_by_user_id: owner.id,
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

             enqueue_deletion!(request)
             true
           end
         end) do
      {:ok, enqueued?} -> enqueued?
      {:error, _reason} -> false
    end
  end

  defp deletion_plan(request) do
    message_ids = deletion_message_ids(request)

    attachment_query =
      from(a in Attachment,
        where: a.tenant_id == ^request.tenant_id and a.status != :deleted
      )

    attachment_query =
      case request.target_type do
        :user ->
          where(
            attachment_query,
            [a],
            a.owner_user_id == ^request.subject_user_id or a.message_id in ^message_ids
          )

        _ ->
          if retention_keeps_attachments?(request) do
            where(attachment_query, [a], false)
          else
            where(attachment_query, [a], a.message_id in ^message_ids)
          end
      end

    attachments =
      attachment_query
      |> order_by([a], asc: a.id)
      |> Repo.all()
      |> Enum.map(fn attachment ->
        %{
          id: attachment.id,
          tenant_id: attachment.tenant_id,
          object_key: attachment.object_key,
          object_version_id: Map.get(attachment, :object_version_id)
        }
      end)

    %{
      request_id: request.id,
      tenant_id: request.tenant_id,
      target_type: request.target_type,
      message_ids: message_ids,
      attachments: attachments
    }
  end

  defp retention_keeps_attachments?(request) do
    value(request.evidence || %{}, :retention_delete_attachments) == false
  end

  defp deletion_message_ids(%DeletionRequest{target_type: :user} = request) do
    Repo.all(
      from(m in Message,
        where: m.tenant_id == ^request.tenant_id and m.sender_user_id == ^request.subject_user_id,
        select: m.id
      )
    )
  end

  defp deletion_message_ids(%DeletionRequest{target_type: :conversation} = request) do
    Repo.all(
      from(m in Message,
        where:
          m.tenant_id == ^request.tenant_id and
            m.conversation_id == ^request.conversation_id,
        select: m.id
      )
    )
  end

  defp deletion_message_ids(%DeletionRequest{target_type: :message, message_id: id}), do: [id]

  defp apply_deletion!(request, plan) do
    timestamp = now()
    message_ids = plan.message_ids
    attachment_ids = Enum.map(plan.attachments, & &1.id)

    content_result =
      Messaging.tombstone_for_erasure(request.tenant_id, message_ids, timestamp)
      |> owner_command_or_rollback()

    attachment_result =
      Attachments.mark_deleted_for_erasure(request.tenant_id, attachment_ids, timestamp)
      |> owner_command_or_rollback()

    revoked_session_ids = apply_target_deletion!(request, timestamp)

    %{
      messages_tombstoned: content_result.messages_tombstoned,
      attachments_deleted: attachment_result.attachments_deleted,
      revoked_session_ids: revoked_session_ids
    }
  end

  defp apply_target_deletion!(%DeletionRequest{target_type: :message}, _timestamp), do: []

  defp apply_target_deletion!(%DeletionRequest{target_type: :conversation} = request, timestamp) do
    Conversations.archive_for_erasure(request.tenant_id, request.conversation_id, timestamp)
    |> owner_command_or_rollback()

    audio_revocation_ok!(
      AudioCalls.revoke_for_conversation(
        request.tenant_id,
        request.conversation_id,
        "governance_conversation_deleted"
      )
    )

    []
  end

  defp apply_target_deletion!(%DeletionRequest{target_type: :user} = request, timestamp) do
    identity_result =
      Accounts.erase_user_for_governance(%{
        tenant_id: request.tenant_id,
        user_id: request.subject_user_id,
        pending_deletion_user_ids: pending_deletion_user_ids(request.tenant_id),
        timestamp: timestamp
      })
      |> owner_command_or_rollback()

    Conversations.remove_user_memberships_for_erasure(
      request.tenant_id,
      identity_result.user_id,
      timestamp
    )
    |> owner_command_or_rollback()

    audio_revocation_ok!(
      AudioCalls.revoke_for_user(
        request.tenant_id,
        identity_result.user_id,
        "governance_user_deleted"
      )
    )

    identity_result.revoked_session_ids
  end

  defp pending_deletion_user_ids(tenant_id) do
    Repo.all(
      from(r in DeletionRequest,
        where:
          r.tenant_id == ^tenant_id and r.target_type == :user and
            r.status in [:approved, :in_progress],
        select: r.subject_user_id
      )
    )
  end

  defp ensure_deletable_owner!(%User{role: :owner, status: :active} = user) do
    pending_deletions =
      from(r in DeletionRequest,
        where:
          r.tenant_id == ^user.tenant_id and r.target_type == :user and
            r.status in [:approved, :in_progress],
        select: r.subject_user_id
      )

    remaining =
      Repo.aggregate(
        from(u in User,
          where:
            u.tenant_id == ^user.tenant_id and u.id != ^user.id and u.role == :owner and
              u.status == :active and u.id not in subquery(pending_deletions)
        ),
        :count
      )

    if remaining == 0, do: Repo.rollback(:last_owner_required)
  end

  defp ensure_deletable_owner!(_user), do: :ok

  defp ensure_deletion_preconditions!(%DeletionRequest{target_type: :user} = request) do
    Repo.all(
      from(u in User,
        where: u.tenant_id == ^request.tenant_id,
        order_by: [asc: u.id],
        select: u.id,
        lock: "FOR UPDATE"
      )
    )

    user =
      Repo.get_by(User, id: request.subject_user_id, tenant_id: request.tenant_id) ||
        Repo.rollback(:not_found)

    ensure_deletable_owner!(user)
  end

  defp ensure_deletion_preconditions!(_request), do: :ok

  defp target_digest(request) do
    [
      request.tenant_id,
      request.target_type,
      request.subject_user_id,
      request.conversation_id,
      request.message_id
    ]
    |> Enum.map_join(":", &to_string(&1 || ""))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp governance_lock!(tenant_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [tenant_id]
    )

    :ok
  end

  defp legal_hold_blocks?(request) do
    {conversation_ids, protected_user_ids} = protected_targets(request)

    active_legal_hold?(request.tenant_id, conversation_ids, protected_user_ids)
  end

  defp active_legal_hold?(tenant_id, conversation_ids, protected_user_ids) do
    applies = dynamic([h], h.scope_type == :tenant)

    applies =
      if protected_user_ids != [] do
        dynamic(
          [h],
          ^applies or (h.scope_type == :user and h.subject_user_id in ^protected_user_ids)
        )
      else
        applies
      end

    applies =
      if conversation_ids != [] do
        dynamic(
          [h],
          ^applies or (h.scope_type == :conversation and h.conversation_id in ^conversation_ids)
        )
      else
        applies
      end

    query =
      from(h in LegalHold,
        where: h.tenant_id == ^tenant_id and h.status == :active
      )

    Repo.exists?(where(query, ^applies))
  end

  defp protected_targets(%DeletionRequest{target_type: :user} = request) do
    conversation_ids =
      Repo.all(
        from(m in Message,
          where:
            m.tenant_id == ^request.tenant_id and m.sender_user_id == ^request.subject_user_id,
          distinct: true,
          select: m.conversation_id
        )
      )

    {conversation_ids, [request.subject_user_id]}
  end

  defp protected_targets(%DeletionRequest{target_type: :message} = request) do
    case Repo.get_by(Message, id: request.message_id, tenant_id: request.tenant_id) do
      %Message{conversation_id: conversation_id, sender_user_id: sender_user_id} ->
        {[conversation_id], [sender_user_id]}

      nil ->
        {[], []}
    end
  end

  defp protected_targets(%DeletionRequest{target_type: :conversation} = request) do
    user_ids =
      Repo.all(
        from(m in Message,
          where:
            m.tenant_id == ^request.tenant_id and
              m.conversation_id == ^request.conversation_id,
          distinct: true,
          select: m.sender_user_id
        )
      )

    {[request.conversation_id], user_ids}
  end

  defp validate_deletion_transition!(current, requested) do
    valid = %{
      pending: [:approved, :rejected, :cancelled],
      approved: [:in_progress, :cancelled],
      in_progress: [:completed, :cancelled],
      completed: [],
      rejected: [],
      cancelled: []
    }

    unless requested in Map.fetch!(valid, current),
      do: Repo.rollback(:invalid_status_transition)
  end

  defp administrative_deletion_status(value) do
    allowed = [:approved, :rejected, :cancelled]

    case enum(value, allowed) do
      nil -> {:error, :invalid_status}
      status -> {:ok, status}
    end
  end

  defp existing_idempotent(_schema, _tenant_id, nil), do: nil

  defp existing_idempotent(schema, tenant_id, key),
    do: Repo.get_by(schema, tenant_id: tenant_id, idempotency_key: key)

  defp maybe_equal(query, _field, nil), do: query
  defp maybe_equal(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp expected_version(attrs) do
    case value(attrs, :version) || value(attrs, :lock_version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  defp enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp enum(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp enum(_, _), do: nil

  defp require_reason(value) when is_binary(value) do
    if String.length(String.trim(value)) in 3..1_000,
      do: :ok,
      else: {:error, :reason_required}
  end

  defp require_reason(_), do: {:error, :reason_required}

  defp require_reason_for_change(attrs, field, reason_field) do
    case fetch_value(attrs, field) do
      {:ok, _value} -> require_reason(value(attrs, reason_field))
      :error -> :ok
    end
  end

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_limit(number)
      _ -> 50
    end
  end

  defp parse_limit(_), do: 50

  defp default(nil, value), do: value
  defp default(value, _default), do: value

  defp schema_resource(RetentionPolicy), do: "retention_policy"

  defp audit!(subject, action, resource_type, resource_id, metadata) do
    subject
    |> audit_command(action, resource_type, resource_id, metadata)
    |> Audit.record()
    |> audit_or_rollback()
  end

  defp audit_system!(tenant_id, action, resource_id, metadata) do
    Audit.record(%{
      tenant_id: tenant_id,
      actor_user_id: nil,
      action: action,
      resource_type: "deletion_request",
      resource_id: resource_id,
      metadata: metadata,
      request_id: "worker:deletion"
    })
    |> audit_or_rollback()
  end

  defp audit_command(subject, action, resource_type, resource_id, metadata) do
    %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    }
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp audio_revocation_ok!({:ok, _count}), do: :ok
  defp audio_revocation_ok!({:error, reason}), do: Repo.rollback(reason)
  defp authorization_or_rollback!(:ok), do: :ok
  defp authorization_or_rollback!({:error, reason}), do: Repo.rollback(reason)
  defp owner_command_or_rollback({:ok, result}), do: result
  defp owner_command_or_rollback({:error, reason}), do: Repo.rollback(reason)

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp value(map, key) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
