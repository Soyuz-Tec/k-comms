defmodule CommsCore.Governance.DeletionWorkflow do
  @moduledoc false

  import Ecto.Query
  import CommsCore.Governance.Support

  alias CommsCore.Audit
  alias CommsCore.Administration.DomainUserErasureCommand
  alias CommsCore.Administration.DomainUserErasureReceipt
  alias CommsCore.Administration.WorkspaceDomainErasure
  alias CommsCore.Accounts.{GovernanceErasureCommand, GovernanceErasureReceipt}

  alias CommsCore.Governance.{
    Authorization,
    DeletionExecution,
    DeletionRequest,
    LegalHold,
    TenantLock
  }

  alias CommsCore.Messaging.{GovernanceImpact, MessageDeletionCandidate}

  alias CommsCore.{
    Accounts,
    Attachments,
    AudioCalls,
    Conversations,
    Integrations,
    Messaging,
    Outbox,
    Repo,
    RuntimePorts,
    SharedDocuments,
    Telephony,
    Whiteboards
  }

  def authorize_message_deletion(%MessageDeletionCandidate{} = candidate) do
    TenantLock.lock!(candidate.tenant_id)

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

  def create_deletion_request(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- Authorization.authorize(subject),
         :ok <- validate_deletion_target(attrs, tenant_id) do
      case existing_idempotent(DeletionRequest, tenant_id, idempotency_key) do
        %DeletionRequest{} = request -> {:ok, %{request: request, replayed: true}}
        nil -> insert_deletion_request(attrs, subject)
      end
    end
  end

  def list_deletion_requests(params, subject) do
    with :ok <- Authorization.authorize(subject) do
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

    with :ok <- Authorization.authorize(subject),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, status} <- administrative_deletion_status(value(attrs, :status)),
         :ok <- require_reason(value(attrs, :transition_reason)) do
      Repo.transaction(fn ->
        TenantLock.lock!(tenant_id)

        Authorization.authorize(subject)
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

        # Preparation commits the media stop/purge jobs before the deletion
        # adapter can report completion. A retry observes the same durable fence.
        prepare_media_erasure!(request)

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

        if media_erasure_pending!(request), do: Repo.rollback(:media_erasure_pending)
        deleted_object_count = value(worker_evidence, :deleted_object_count)

        unless is_integer(deleted_object_count) and deleted_object_count >= 0,
          do: Repo.rollback(:deletion_evidence_mismatch)

        timestamp = now()
        identity_result = prepare_user_deletion!(request, timestamp)
        plan = fenced_deletion_plan!(request, timestamp)

        unless is_integer(deleted_object_count) and
                 deleted_object_count == length(plan.attachments),
               do: Repo.rollback(:deletion_evidence_mismatch)

        results = apply_deletion!(request, plan, timestamp, identity_result)

        evidence =
          %{
            executor: RuntimePorts.job_worker_name!(:deletion),
            completed_at: DateTime.to_iso8601(now()),
            target_type: request.target_type,
            messages_tombstoned: results.messages_tombstoned,
            attachments_deleted: results.attachments_deleted,
            deleted_object_count: deleted_object_count,
            derived_erasure_version: 1,
            media_erasure_version: 1,
            meeting_erasure_version: 1,
            calendar_erasure_version: 1,
            ivr_agent_state_erasure_version: 1,
            writer_fence_erasure_version: 1,
            shared_document_erasure_version: 1,
            shared_documents_erased: results.shared_documents_erased,
            shared_document_operations_deleted: results.shared_document_operations_deleted,
            target_digest: target_digest(request)
          }
          |> Map.merge(domain_erasure_evidence(request, results))

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

  def reconcile_completed_erasure(caller, limit) when is_integer(limit) and limit in 1..100 do
    if RuntimePorts.authorized_job_worker?(:erasure_reconciler, caller) do
      ids =
        Repo.all(
          from(request in DeletionRequest,
            where:
              request.status == :completed and
                (fragment("coalesce(?->>'derived_erasure_version', '') <> '1'", request.evidence) or
                   fragment("coalesce(?->>'media_erasure_version', '') <> '1'", request.evidence) or
                   fragment(
                     "coalesce(?->>'meeting_erasure_version', '') <> '1'",
                     request.evidence
                   ) or
                   fragment(
                     "coalesce(?->>'ivr_agent_state_erasure_version', '') <> '1'",
                     request.evidence
                   ) or
                   fragment(
                     "coalesce(?->>'calendar_erasure_version', '') <> '1'",
                     request.evidence
                   ) or
                   fragment(
                     "coalesce(?->>'writer_fence_erasure_version', '') <> '1'",
                     request.evidence
                   ) or
                   fragment(
                     "coalesce(?->>'shared_document_erasure_version', '') <> '1'",
                     request.evidence
                   ) or
                   (request.target_type == :user and
                      fragment(
                        "coalesce(?->>'domain_challenge_erasure_version', '') <> '1'",
                        request.evidence
                      ))),
            order_by: [
              asc: fragment("coalesce(?->>'media_erasure_checked_at', '')", request.evidence),
              asc: request.completed_at,
              asc: request.id
            ],
            limit: ^limit,
            select: request.id
          )
        )

      Enum.reduce_while(ids, {:ok, 0}, fn id, {:ok, count} ->
        case repair_completed_erasure(id) do
          {:ok, repaired?} ->
            {:cont, {:ok, count + if(repaired?, do: 1, else: 0)}}

          {:error, :legal_hold_active} ->
            record_media_erasure_check(id)
            {:cont, {:ok, count}}

          {:error, _} ->
            {:halt, {:error, :erasure_repair_failed}}
        end
      end)
      |> case do
        {:ok, count} -> {:ok, %{repaired: count, has_more: length(ids) == limit}}
        {:error, _} = error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  def reconcile_completed_erasure(_, _), do: {:error, :forbidden}

  defp repair_completed_erasure(id) do
    Repo.transaction(fn ->
      request = lock_deletion_request_for_worker!(id)

      if request.status != :completed or
           (value(request.evidence || %{}, :derived_erasure_version) == 1 and
              value(request.evidence || %{}, :media_erasure_version) == 1 and
              value(request.evidence || %{}, :meeting_erasure_version) == 1 and
              value(request.evidence || %{}, :writer_fence_erasure_version) == 1 and
              value(request.evidence || %{}, :shared_document_erasure_version) == 1 and
              value(request.evidence || %{}, :ivr_agent_state_erasure_version) == 1 and
              value(request.evidence || %{}, :calendar_erasure_version) == 1 and
              domain_erasure_current?(request)) do
        false
      else
        prepare_media_erasure!(request)
        pending = media_erasure_pending!(request)

        evidence =
          Map.merge(request.evidence || %{}, %{
            "media_erasure_checked_at" => DateTime.to_iso8601(now())
          })

        if pending do
          request |> DeletionRequest.changeset(%{evidence: evidence}) |> update_or_rollback()
          false
        else
          timestamp = now()
          identity_result = prepare_user_deletion!(request, timestamp)
          plan = fenced_deletion_plan!(request, timestamp)

          if plan.attachments == [] do
            results = apply_deletion!(request, plan, timestamp, identity_result)

            evidence =
              Map.merge(evidence, %{
                "derived_erasure_version" => 1,
                "media_erasure_version" => 1,
                "meeting_erasure_version" => 1,
                "ivr_agent_state_erasure_version" => 1,
                "calendar_erasure_version" => 1,
                "writer_fence_erasure_version" => 1,
                "shared_document_erasure_version" => 1,
                "shared_documents_erased" => results.shared_documents_erased,
                "shared_document_operations_deleted" =>
                  results.shared_document_operations_deleted,
                "derived_erasure_repaired_at" => DateTime.to_iso8601(now())
              })
              |> Map.merge(
                Map.new(domain_erasure_evidence(request, results), fn {key, value} ->
                  {Atom.to_string(key), value}
                end)
              )

            request |> DeletionRequest.changeset(%{evidence: evidence}) |> update_or_rollback()

            audit_system!(
              request.tenant_id,
              "deletion_request.derived_content_repaired",
              request.id,
              Map.merge(
                %{
                  derived_erasure_version: 1,
                  media_erasure_version: 1,
                  meeting_erasure_version: 1,
                  calendar_erasure_version: 1,
                  writer_fence_erasure_version: 1,
                  shared_document_erasure_version: 1,
                  ivr_agent_state_erasure_version: 1
                },
                domain_erasure_evidence(request, results)
              )
            )

            true
          else
            requeue_writer_fence_repair!(request, evidence, timestamp)
            false
          end
        end
      end
    end)
  end

  defp requeue_writer_fence_repair!(request, evidence, timestamp) do
    evidence =
      evidence
      |> Map.drop([:writer_fence_erasure_version, "writer_fence_erasure_version"])
      |> Map.put("writer_fence_repair_queued_at", DateTime.to_iso8601(timestamp))
      |> Map.put(
        "historical_completed_at",
        DateTime.to_iso8601(request.completed_at || timestamp)
      )

    updated =
      request
      |> DeletionRequest.changeset(%{
        status: :in_progress,
        completed_at: nil,
        evidence: evidence,
        execution_error: "writer_fence_repair_pending"
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    enqueue_deletion!(updated)

    audit_system!(request.tenant_id, "deletion_request.writer_fence_repair_queued", request.id, %{
      version: updated.lock_version,
      writer_fence_erasure_version: 0
    })
  end

  defp record_media_erasure_check(id) do
    Repo.transaction(fn ->
      request = lock_deletion_request_for_worker!(id)

      evidence =
        Map.put(request.evidence || %{}, "media_erasure_checked_at", DateTime.to_iso8601(now()))

      request |> DeletionRequest.changeset(%{evidence: evidence}) |> update_or_rollback()
    end)
  end

  defp media_target(%DeletionRequest{target_type: :user} = request), do: request.subject_user_id

  defp media_target(%DeletionRequest{target_type: :conversation} = request),
    do: request.conversation_id

  defp media_target(%DeletionRequest{target_type: :message} = request), do: request.message_id

  defp prepare_media_erasure!(request) do
    target = media_target(request)

    with {:ok, _} <-
           AudioCalls.prepare_calendar_governance_erasure(
             request.tenant_id,
             request.target_type,
             target
           ),
         {:ok, _} <-
           AudioCalls.prepare_governance_erasure(request.tenant_id, request.target_type, target),
         {:ok, _} <-
           Telephony.prepare_governance_erasure(request.tenant_id, request.target_type, target),
         {:ok, _} <-
           AudioCalls.prepare_meeting_governance_erasure(
             request.tenant_id,
             request.target_type,
             target
           ) do
      :ok
    else
      {:error, reason}
      when reason in [
             :artifact_legal_hold,
             :voicemail_legal_hold,
             :meeting_legal_hold,
             :calendar_legal_hold,
             :legal_hold_active
           ] ->
        Repo.rollback(:legal_hold_active)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp media_erasure_pending!(request) do
    target = media_target(request)

    with {:ok, calls_pending} <-
           AudioCalls.governance_erasure_pending?(request.tenant_id, request.target_type, target),
         {:ok, voicemail_pending} <-
           Telephony.governance_erasure_pending?(request.tenant_id, request.target_type, target),
         {:ok, meetings_pending} <-
           AudioCalls.meeting_governance_erasure_pending?(
             request.tenant_id,
             request.target_type,
             target
           ) do
      calendar_pending =
        case AudioCalls.calendar_governance_erasure_pending?(
               request.tenant_id,
               request.target_type,
               target
             ) do
          {:ok, pending} -> pending
          {:error, reason} -> Repo.rollback(reason)
        end

      calls_pending or voicemail_pending or meetings_pending or calendar_pending
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

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

  defp lock_deletion_request_for_worker!(id) do
    tenant_id =
      Repo.one(from(r in DeletionRequest, where: r.id == ^id, select: r.tenant_id)) ||
        Repo.rollback(:not_found)

    TenantLock.lock!(tenant_id)

    Repo.one(
      from(r in DeletionRequest,
        where: r.id == ^id and r.tenant_id == ^tenant_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp validate_deletion_target(attrs, tenant_id) do
    case enum(value(attrs, :target_type), [:user, :conversation, :message]) do
      :user ->
        tenant_id
        |> Accounts.validate_governance_user(value(attrs, :subject_user_id))
        |> governance_target_result()

      :conversation ->
        tenant_id
        |> Conversations.validate_reference(value(attrs, :conversation_id))
        |> governance_target_result()

      :message ->
        validate_message_target(tenant_id, value(attrs, :message_id))

      nil ->
        {:error, :invalid_governance_target}
    end
  end

  defp validate_message_target(tenant_id, message_id)
       when is_binary(tenant_id) and is_binary(message_id) do
    case Messaging.governance_impact(tenant_id, :message, message_id) do
      %GovernanceImpact{found?: true} -> :ok
      %GovernanceImpact{} -> {:error, :invalid_governance_target}
    end
  end

  defp validate_message_target(_tenant_id, _message_id),
    do: {:error, :invalid_governance_target}

  def enqueue_deletion!(request) do
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

  defp deletion_plan(request) do
    message_ids = deletion_message_ids(request)

    deletion_plan(request, message_ids)
  end

  defp deletion_plan(request, message_ids) do
    attachments =
      case request.target_type do
        :user ->
          Attachments.erasure_objects(
            request.tenant_id,
            message_ids,
            request.subject_user_id
          )

        _ ->
          if retention_keeps_attachments?(request) do
            []
          else
            Attachments.erasure_objects(request.tenant_id, message_ids, nil)
          end
      end

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
    %GovernanceImpact{message_ids: message_ids} =
      Messaging.governance_impact(request.tenant_id, :user, request.subject_user_id)

    message_ids
  end

  defp deletion_message_ids(%DeletionRequest{target_type: :conversation} = request) do
    %GovernanceImpact{message_ids: message_ids} =
      Messaging.governance_impact(request.tenant_id, :conversation, request.conversation_id)

    message_ids
  end

  defp deletion_message_ids(%DeletionRequest{target_type: :message, message_id: id}), do: [id]

  defp fenced_deletion_plan!(request, timestamp) do
    # Archiving conflicts with the retained Conversation SHARE of content
    # writers. Message parents then drain admitted edits before any revision,
    # derived-copy, or attachment scope is selected.
    if request.target_type == :conversation do
      Conversations.archive_for_erasure(request.tenant_id, request.conversation_id, timestamp)
      |> owner_command_or_rollback()
    end

    %GovernanceImpact{message_ids: message_ids} =
      Messaging.lock_for_erasure(request.tenant_id, request.target_type, media_target(request))
      |> owner_command_or_rollback()

    if legal_hold_blocks?(request), do: Repo.rollback(:legal_hold_active)
    deletion_plan(request, message_ids)
  end

  defp prepare_user_deletion!(%DeletionRequest{target_type: :user} = request, timestamp) do
    # Retain current writers before selecting any final content scope. The
    # IdentityAccess drains Sessions/Devices while retaining its sorted user
    # fence. Keyed anonymization happens after lower call/content effects.
    ensure_deletion_preconditions!(request)
    if legal_hold_blocks?(request), do: Repo.rollback(:legal_hold_active)
    if media_erasure_pending!(request), do: Repo.rollback(:media_erasure_pending)

    identity_result =
      request
      |> identity_erasure_command(timestamp)
      |> Accounts.drain_user_for_governance()
      |> owner_command_or_rollback()

    # Refresh the media proof after the actual identity drain while all user
    # writers remain fenced; any newly pending work rolls the drain back.
    prepare_media_erasure!(request)
    if media_erasure_pending!(request), do: Repo.rollback(:media_erasure_pending)
    if legal_hold_blocks?(request), do: Repo.rollback(:legal_hold_active)
    identity_result
  end

  defp prepare_user_deletion!(_request, _timestamp), do: nil

  defp apply_deletion!(request, plan, timestamp, identity_result) do
    message_ids = plan.message_ids
    attachment_ids = Enum.map(plan.attachments, & &1.id)

    erase_derived_message_content!(request.tenant_id, message_ids)

    content_result =
      Messaging.tombstone_for_erasure(request.tenant_id, message_ids, timestamp)
      |> owner_command_or_rollback()

    attachment_result =
      Attachments.mark_deleted_for_erasure(request.tenant_id, attachment_ids, timestamp)
      |> owner_command_or_rollback()

    whiteboard_result =
      erase_whiteboards(request, timestamp)
      |> owner_command_or_rollback()

    document_result = erase_documents!(request, timestamp)
    erase_personal_content!(request)

    {revoked_session_ids, domain_receipt} =
      apply_target_deletion!(request, timestamp, identity_result)

    %{
      messages_tombstoned: content_result.messages_tombstoned,
      attachments_deleted: attachment_result.attachments_deleted,
      whiteboards_deleted: whiteboard_result.whiteboards_deleted,
      whiteboard_operations_deleted: whiteboard_result.whiteboard_operations_deleted,
      whiteboard_operations_neutralized: whiteboard_result.whiteboard_operations_neutralized,
      revoked_session_ids: revoked_session_ids,
      shared_documents_erased: document_result.documents_erased,
      shared_document_operations_deleted: document_result.operations_deleted,
      domain_receipt: domain_receipt
    }
  end

  defp erase_documents!(%DeletionRequest{target_type: :message}, _timestamp),
    do: %CommsCore.SharedDocuments.ErasureReceipt{}

  defp erase_documents!(request, timestamp) do
    SharedDocuments.erase_for_governance(
      request.tenant_id,
      request.target_type,
      media_target(request),
      timestamp
    )
    |> owner_command_or_rollback()
  end

  defp erase_personal_content!(%DeletionRequest{target_type: :message}), do: :ok

  defp erase_personal_content!(request) do
    target_id =
      if request.target_type == :user, do: request.subject_user_id, else: request.conversation_id

    case Messaging.erase_personal_content(request.tenant_id, request.target_type, target_id) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp erase_derived_message_content!(tenant_id, message_ids) do
    event_ids =
      Outbox.erase_message_content(tenant_id, message_ids) |> owner_command_or_rollback()

    Integrations.erase_message_content(tenant_id, event_ids) |> owner_command_or_rollback()
  end

  defp erase_whiteboards(%DeletionRequest{target_type: :conversation} = request, timestamp) do
    Whiteboards.erase_for_governance(
      request.tenant_id,
      :conversation,
      request.conversation_id,
      timestamp
    )
  end

  defp erase_whiteboards(%DeletionRequest{target_type: :user} = request, timestamp) do
    Whiteboards.erase_for_governance(
      request.tenant_id,
      :user,
      request.subject_user_id,
      timestamp
    )
  end

  defp erase_whiteboards(%DeletionRequest{target_type: :message}, _timestamp) do
    {:ok,
     %{
       whiteboards_deleted: 0,
       whiteboard_operations_deleted: 0,
       whiteboard_operations_neutralized: 0
     }}
  end

  defp apply_target_deletion!(
         %DeletionRequest{target_type: :message},
         _timestamp,
         _identity_result
       ),
       do: {[], nil}

  defp apply_target_deletion!(
         %DeletionRequest{target_type: :conversation} = request,
         _timestamp,
         _identity_result
       ) do
    audio_revocation_ok!(
      AudioCalls.revoke_for_conversation(
        request.tenant_id,
        request.conversation_id,
        "governance_conversation_deleted"
      )
    )

    {[], nil}
  end

  defp apply_target_deletion!(
         %DeletionRequest{target_type: :user} = request,
         timestamp,
         %GovernanceErasureReceipt{user_id: user_id, revoked_session_ids: revoked_session_ids}
       ) do
    Conversations.remove_user_memberships_for_erasure(
      request.tenant_id,
      user_id,
      timestamp
    )
    |> owner_command_or_rollback()

    domain_receipt =
      WorkspaceDomainErasure.erase_user_challenges(%DomainUserErasureCommand{
        tenant_id: request.tenant_id,
        user_id: user_id,
        timestamp: timestamp
      })
      |> owner_command_or_rollback()

    # The drain already contributed room and telephone call revocation. Strong
    # identity-key updates are last, after every lower call/content resource.
    Telephony.erase_agent_queue_state(request.tenant_id, user_id)
    |> owner_command_or_rollback()

    request
    |> identity_erasure_command(timestamp)
    |> Accounts.finalize_user_for_governance_erasure()
    |> owner_command_or_rollback()

    {revoked_session_ids, domain_receipt}
  end

  defp domain_erasure_current?(%DeletionRequest{target_type: :user} = request),
    do: value(request.evidence || %{}, :domain_challenge_erasure_version) == 1

  defp domain_erasure_current?(_request), do: true

  defp domain_erasure_evidence(%DeletionRequest{target_type: :user}, %{
         domain_receipt: %DomainUserErasureReceipt{} = receipt
       }) do
    %{
      domain_challenge_erasure_version: 1,
      domain_challenges_removed: receipt.removed_challenges,
      domain_verified_leases_detached: receipt.detached_verified_leases
    }
  end

  defp domain_erasure_evidence(_request, _results), do: %{}

  defp identity_erasure_command(request, timestamp) do
    %GovernanceErasureCommand{
      tenant_id: request.tenant_id,
      user_id: request.subject_user_id,
      pending_deletion_user_ids: pending_deletion_user_ids(request.tenant_id),
      timestamp: timestamp
    }
  end

  def pending_deletion_user_ids(tenant_id) do
    Repo.all(
      from(r in DeletionRequest,
        where:
          r.tenant_id == ^tenant_id and r.target_type == :user and
            r.status in [:approved, :in_progress],
        select: r.subject_user_id
      )
    )
  end

  defp ensure_deletion_preconditions!(%DeletionRequest{target_type: :user} = request) do
    Accounts.ensure_governance_erasure_allowed(
      request.tenant_id,
      request.subject_user_id,
      pending_deletion_user_ids(request.tenant_id)
    )
    |> precondition_or_rollback!()
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
    %GovernanceImpact{conversation_ids: conversation_ids} =
      Messaging.governance_impact(request.tenant_id, :user, request.subject_user_id)

    {conversation_ids, [request.subject_user_id]}
  end

  defp protected_targets(%DeletionRequest{target_type: :message} = request) do
    %GovernanceImpact{conversation_ids: conversation_ids, user_ids: user_ids} =
      Messaging.governance_impact(request.tenant_id, :message, request.message_id)

    {conversation_ids, user_ids}
  end

  defp protected_targets(%DeletionRequest{target_type: :conversation} = request) do
    %GovernanceImpact{user_ids: user_ids} =
      Messaging.governance_impact(request.tenant_id, :conversation, request.conversation_id)

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

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
