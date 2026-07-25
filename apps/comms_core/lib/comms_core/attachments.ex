defmodule CommsCore.Attachments do
  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Conversations, Repo, RuntimePorts}

  alias CommsCore.Attachments.{
    Attachment,
    AttachmentDeletionObject,
    AttachmentView,
    FileView,
    Projector,
    RestoreCandidate,
    RestoreContext,
    RestoreRemap,
    RestoreReport,
    RestoredObjectIdentity,
    ScanAttempt
  }

  alias CommsCore.Audit

  @allowed_prefixes ["image/", "text/"]
  @allowed_exact ["application/pdf", "application/zip", "application/json"]
  @default_max_bytes 26_214_400
  @schema_max_bytes 1_073_741_824
  @scan_claim_timeout_seconds 300
  @default_file_limit 30
  @max_file_limit 100
  @max_upload_ttl_seconds 3_600
  @default_cleanup_grace_seconds 300
  @default_cleanup_claim_timeout_seconds 900
  @default_cleanup_reconcile_limit 100

  @doc """
  Verifies and atomically remaps restored attachment object versions.

  The verifier receives a persistence-neutral `RestoreCandidate`; attachment
  schemas and lifecycle state remain internal to this boundary.
  """
  @spec remap_restored_attachment_versions(
          (RestoreCandidate.t() -> {:ok, RestoredObjectIdentity.t()} | {:error, term()}),
          RestoreContext.t()
        ) :: {:ok, RestoreReport.t()} | {:error, term()}
  def remap_restored_attachment_versions(verifier, %RestoreContext{} = context)
      when is_function(verifier, 1) do
    RestoreRemap.run(verifier, context)
  end

  def remap_restored_attachment_versions(_verifier, _context),
    do: {:error, :invalid_restore_remap_invocation}

  @doc """
  Returns the object-storage identities owned by an attachment erasure scope.

  Message-owned attachments are selected by `message_ids`. When
  `owner_user_id` is present, attachments directly owned by that user are
  included as the same tenant-scoped union. Deleted rows are never returned.
  Invalid scopes fail closed with an empty projection.
  """
  @spec erasure_objects(String.t(), [String.t()], String.t() | nil) ::
          [AttachmentDeletionObject.t()]
  def erasure_objects(tenant_id, message_ids, owner_user_id)
      when is_binary(tenant_id) and is_list(message_ids) and
             (is_binary(owner_user_id) or is_nil(owner_user_id)) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, message_ids} <- cast_uuid_list(message_ids),
         {:ok, owner_user_id} <- cast_optional_uuid(owner_user_id) do
      Attachment
      |> where([attachment], attachment.tenant_id == ^tenant_id)
      |> where([attachment], attachment.status != :deleted)
      |> erasure_scope_filter(message_ids, owner_user_id)
      |> order_by([attachment], asc: attachment.id)
      |> select([attachment], %{
        id: attachment.id,
        tenant_id: attachment.tenant_id,
        object_key: attachment.object_key,
        object_version_id: attachment.object_version_id
      })
      |> Repo.all()
      |> Enum.map(&struct!(AttachmentDeletionObject, &1))
    else
      _ -> []
    end
  end

  def erasure_objects(_tenant_id, _message_ids, _owner_user_id), do: []

  @doc """
  Marks tenant-scoped attachments deleted as part of an existing erasure transaction.

  The persisted row is retained while user-visible file identity and the source
  checksum are scrubbed. Returns only the number of affected rows.
  """
  @spec mark_deleted_for_erasure(Ecto.UUID.t(), [Ecto.UUID.t()], DateTime.t()) ::
          {:ok, %{attachments_deleted: non_neg_integer()}}
          | {:error, :invalid_erasure_scope | :transaction_required}
  def mark_deleted_for_erasure(tenant_id, attachment_ids, %DateTime{} = timestamp)
      when is_binary(tenant_id) and is_list(attachment_ids) do
    if Repo.in_transaction?() do
      attachment_ids = Enum.uniq(attachment_ids)

      with :ok <- validate_erasure_scope(tenant_id, attachment_ids) do
        {attachments_deleted, _} =
          Repo.update_all(
            from(attachment in Attachment,
              where: attachment.tenant_id == ^tenant_id and attachment.id in ^attachment_ids
            ),
            set: [
              status: :deleted,
              file_name: "deleted",
              content_type: "application/octet-stream",
              checksum_sha256: nil,
              updated_at: timestamp
            ]
          )

        {:ok, %{attachments_deleted: attachments_deleted}}
      end
    else
      {:error, :transaction_required}
    end
  end

  def mark_deleted_for_erasure(_tenant_id, _attachment_ids, _timestamp),
    do: {:error, :invalid_erasure_scope}

  def create_intent(attrs, subject) do
    content_type = value(attrs, :content_type) || "application/octet-stream"
    byte_size = integer(value(attrs, :byte_size))
    checksum = normalize_checksum(value(attrs, :checksum_sha256))

    with {:ok, max_bytes} <- attachment_limit(subject),
         :ok <- validate_type(content_type),
         :ok <- validate_size(byte_size, max_bytes),
         :ok <- validate_checksum(checksum) do
      id = Ecto.UUID.generate()
      file_name = sanitize_file_name(value(attrs, :file_name) || "attachment")
      object_key = "#{value(subject, :tenant_id)}/#{id}/#{file_name}"

      %Attachment{id: id}
      |> Attachment.changeset(%{
        tenant_id: value(subject, :tenant_id),
        owner_user_id: value(subject, :user_id),
        object_key: object_key,
        file_name: file_name,
        content_type: content_type,
        byte_size: byte_size,
        checksum_sha256: checksum,
        status: :pending
      })
      |> Repo.insert()
      |> project_result()
    end
  end

  @doc """
  Persists the exact expiry of the upload authorization before it is returned.

  Abandonment cleanup is never allowed to complete before this deadline plus
  the configured settling grace. The bounded deadline is supplied by the
  object-storage signer that generated the authorization.
  """
  @spec record_upload_authorization(String.t(), DateTime.t(), map()) ::
          {:ok, AttachmentView.t()}
          | {:error, :not_found | :attachment_not_pending | :invalid_upload_expiry | term()}
  def record_upload_authorization(id, %DateTime{} = expires_at, subject)
      when is_binary(id) and is_map(subject) do
    current = now()
    expires_at = DateTime.truncate(expires_at, :microsecond)
    ttl_seconds = DateTime.diff(expires_at, current, :second)

    if ttl_seconds in 1..@max_upload_ttl_seconds do
      Repo.transaction(fn ->
        attachment = owned_for_update(id, subject) || Repo.rollback(:not_found)

        if attachment.status != :pending or is_binary(attachment.message_id) do
          Repo.rollback(:attachment_not_pending)
        end

        attachment
        |> Attachment.changeset(%{upload_expires_at: expires_at})
        |> Repo.update!()
      end)
      |> unwrap_transaction()
      |> project_result()
    else
      {:error, :invalid_upload_expiry}
    end
  end

  def record_upload_authorization(_id, _expires_at, _subject),
    do: {:error, :invalid_upload_expiry}

  @doc """
  Abandons an unclaimed attachment and durably schedules key-wide cleanup.

  The command is owner- and tenant-scoped, refuses attachments already claimed
  by a message, and is idempotent after the attachment has entered the deleted
  state. Cleanup is scheduled after the persisted upload authorization expires
  plus a settling grace, then purges every version below the attachment-unique
  object key.
  """
  @spec abandon_intent(String.t(), map()) ::
          {:ok, AttachmentView.t()}
          | {:error, :not_found | :attachment_claimed | term()}
  def abandon_intent(id, subject) when is_binary(id) and is_map(subject) do
    Repo.transaction(fn ->
      attachment = owned_for_update(id, subject) || Repo.rollback(:not_found)

      if is_binary(attachment.message_id) do
        Repo.rollback(:attachment_claimed)
      end

      previous_status = attachment.status

      attachment =
        attachment
        |> abandon_attachment!(current_cleanup_due_at(attachment))

      if previous_status != :deleted do
        audit!(subject, "attachment.abandoned", attachment.id, %{
          previous_status: previous_status
        })
      end

      enqueue_abandon_cleanup!(attachment)
      attachment
    end)
    |> unwrap_transaction()
    |> project_result()
  end

  def abandon_intent(_id, _subject), do: {:error, :not_found}

  @doc """
  Claims a due, tenant-bound cleanup target for the abandonment worker.

  The durable attempt state is advanced before the external purge. A job that
  arrives before the upload expiry is snoozed rather than deleting a key while
  its upload authorization may still be replayed.
  """
  @spec claim_abandon_cleanup(String.t(), String.t(), module()) ::
          {:ok, %{id: String.t(), tenant_id: String.t(), object_key: String.t()}}
          | {:snooze, pos_integer()}
          | {:error, :forbidden | :not_found | :not_abandoned | :cleanup_complete | term()}
  def claim_abandon_cleanup(tenant_id, id, caller)
      when is_binary(tenant_id) and is_binary(id) do
    with true <- RuntimePorts.authorized_job_worker?(:attachment_abandon, caller) do
      case Repo.transaction(fn ->
             attachment =
               Repo.one(
                 from(a in Attachment,
                   where: a.id == ^id and a.tenant_id == ^tenant_id,
                   lock: "FOR UPDATE"
                 )
               ) || Repo.rollback(:not_found)

             cond do
               attachment.status != :deleted or is_binary(attachment.message_id) ->
                 Repo.rollback(:not_abandoned)

               attachment.cleanup_status == :complete ->
                 Repo.rollback(:cleanup_complete)

               delay = cleanup_due_in(attachment, now()) ->
                 {:snooze, delay}

               true ->
                 claimed_at = now()

                 attachment =
                   attachment
                   |> Attachment.changeset(%{
                     cleanup_status: :running,
                     cleanup_attempts: attachment.cleanup_attempts + 1,
                     cleanup_claimed_at: claimed_at,
                     cleanup_last_error: nil
                   })
                   |> Repo.update!()

                 cleanup_target(attachment)
             end
           end) do
        {:ok, {:snooze, seconds}} -> {:snooze, seconds}
        {:ok, %{id: _, tenant_id: _, object_key: _} = target} -> {:ok, target}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :forbidden}
    end
  end

  def claim_abandon_cleanup(_tenant_id, _id, _caller), do: {:error, :not_found}

  @doc """
  Marks a tenant-bound purge complete only after the storage adapter verified
  that no object versions or delete markers remain below the exact key.
  """
  @spec complete_abandon_cleanup(String.t(), String.t(), module()) ::
          {:ok, AttachmentView.t()}
          | {:error, :forbidden | :not_found | :not_abandoned | term()}
  def complete_abandon_cleanup(tenant_id, id, caller)
      when is_binary(tenant_id) and is_binary(id) do
    with true <- RuntimePorts.authorized_job_worker?(:attachment_abandon, caller) do
      Repo.transaction(fn ->
        attachment =
          Repo.one(
            from(a in Attachment,
              where: a.id == ^id and a.tenant_id == ^tenant_id,
              lock: "FOR UPDATE"
            )
          ) ||
            Repo.rollback(:not_found)

        if attachment.status != :deleted or is_binary(attachment.message_id) do
          Repo.rollback(:not_abandoned)
        end

        attachment
        |> Attachment.changeset(%{
          cleanup_status: :complete,
          cleanup_next_attempt_at: nil,
          cleanup_claimed_at: nil,
          cleanup_last_error: nil,
          cleanup_completed_at: now()
        })
        |> Repo.update!()
      end)
      |> unwrap_transaction()
      |> project_result()
    else
      false -> {:error, :forbidden}
    end
  end

  def complete_abandon_cleanup(_tenant_id, _id, _caller), do: {:error, :not_found}

  @doc """
  Persists a bounded cleanup failure and its next reconciliation deadline.

  A terminal Oban attempt is observable as `failed`, but remains eligible for
  the periodic reconciler so a provider outage cannot permanently strand data.
  """
  @spec record_abandon_cleanup_failure(String.t(), String.t(), term(), boolean(), module()) ::
          {:ok, AttachmentView.t()}
          | {:error, :forbidden | :not_found | :not_abandoned | term()}
  def record_abandon_cleanup_failure(tenant_id, id, reason, terminal?, caller)
      when is_binary(tenant_id) and is_binary(id) and is_boolean(terminal?) do
    with true <- RuntimePorts.authorized_job_worker?(:attachment_abandon, caller) do
      Repo.transaction(fn ->
        attachment =
          Repo.one(
            from(a in Attachment,
              where: a.id == ^id and a.tenant_id == ^tenant_id,
              lock: "FOR UPDATE"
            )
          ) ||
            Repo.rollback(:not_found)

        if attachment.status != :deleted or is_binary(attachment.message_id) do
          Repo.rollback(:not_abandoned)
        end

        attachment
        |> Attachment.changeset(%{
          cleanup_status: if(terminal?, do: :failed, else: :retryable),
          cleanup_next_attempt_at:
            DateTime.add(now(), cleanup_retry_delay_seconds(attachment.cleanup_attempts), :second),
          cleanup_claimed_at: nil,
          cleanup_last_error: cleanup_error(reason),
          cleanup_completed_at: nil
        })
        |> Repo.update!()
      end)
      |> unwrap_transaction()
      |> project_result()
    else
      false -> {:error, :forbidden}
    end
  end

  def record_abandon_cleanup_failure(_tenant_id, _id, _reason, _terminal?, _caller),
    do: {:error, :not_found}

  @doc """
  Reconciles stale pending intents and every incomplete cleanup lifecycle.

  The scheduled worker owns no attachment persistence. It calls this
  authorized port, which locks a bounded batch, restores stale claims, and
  transactionally enqueues tenant-bound purge jobs.
  """
  @spec reconcile_abandon_cleanups(module()) ::
          {:ok, %{stale_intents: non_neg_integer(), cleanup_jobs: non_neg_integer()}}
          | {:error, :forbidden | term()}
  def reconcile_abandon_cleanups(caller) do
    with true <- RuntimePorts.authorized_job_worker?(:attachment_abandon_reconciler, caller) do
      Repo.transaction(fn ->
        current = now()
        grace_seconds = cleanup_grace_seconds()

        fallback_cutoff =
          DateTime.add(current, -(@max_upload_ttl_seconds + grace_seconds), :second)

        upload_cutoff = DateTime.add(current, -grace_seconds, :second)
        stale_claim_cutoff = DateTime.add(current, -cleanup_claim_timeout_seconds(), :second)
        limit = cleanup_reconcile_limit()

        stale_intents =
          Attachment
          |> where(
            [attachment],
            attachment.status == :pending and is_nil(attachment.message_id) and
              ((not is_nil(attachment.upload_expires_at) and
                  attachment.upload_expires_at <= ^upload_cutoff) or
                 (is_nil(attachment.upload_expires_at) and
                    attachment.inserted_at <= ^fallback_cutoff))
          )
          |> order_by([attachment], asc: attachment.inserted_at, asc: attachment.id)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.all()
          |> Enum.map(fn attachment ->
            abandon_attachment!(attachment, current)
          end)

        cleanup_candidates =
          Attachment
          |> where(
            [attachment],
            attachment.status == :deleted and is_nil(attachment.message_id) and
              attachment.cleanup_status != :complete and
              ((attachment.cleanup_status in [:scheduled, :retryable, :failed] and
                  (is_nil(attachment.cleanup_next_attempt_at) or
                     attachment.cleanup_next_attempt_at <= ^current)) or
                 (attachment.cleanup_status == :running and
                    attachment.cleanup_claimed_at <= ^stale_claim_cutoff) or
                 (attachment.cleanup_status == :not_required and
                    ((not is_nil(attachment.upload_expires_at) and
                        attachment.upload_expires_at <= ^upload_cutoff) or
                       (is_nil(attachment.upload_expires_at) and
                          attachment.inserted_at <= ^fallback_cutoff))))
          )
          |> order_by([attachment], asc: attachment.cleanup_next_attempt_at, asc: attachment.id)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.all()
          |> Enum.map(&normalize_reconciled_cleanup!(&1, current))

        Enum.each(cleanup_candidates, &enqueue_abandon_cleanup!/1)

        %{
          stale_intents: length(stale_intents),
          cleanup_jobs: length(cleanup_candidates)
        }
      end)
      |> unwrap_transaction()
    else
      false -> {:error, :forbidden}
    end
  end

  def mark_uploaded(id, checksum, identity, subject) do
    checksum = normalize_checksum(checksum)

    with :ok <- validate_checksum(checksum),
         {:ok, identity} <- validate_identity(identity, checksum) do
      Repo.transaction(fn ->
        attachment = owned_for_update(id, subject) || Repo.rollback(:not_found)

        case checksum_matches(attachment, checksum) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        attachment =
          cond do
            attachment.status == :pending ->
              attachment
              |> Attachment.changeset(%{
                checksum_sha256: checksum,
                object_version_id: identity.object_version_id,
                object_etag: identity.object_etag,
                verified_checksum_sha256: identity.verified_checksum_sha256,
                status: :uploaded,
                scan_status: :pending,
                scan_verdict: nil,
                scan_error_code: nil,
                uploaded_at: now()
              })
              |> Repo.update!()

            attachment.status in [:uploaded, :ready] ->
              attachment

            true ->
              Repo.rollback(:attachment_not_pending)
          end

        case maybe_enqueue_scan(attachment) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        attachment
      end)
      |> unwrap_transaction()
      |> project_result()
    end
  end

  def get_authorized(id, subject) do
    with %Attachment{} = attachment <-
           Repo.get_by(Attachment, id: id, tenant_id: value(subject, :tenant_id)),
         :ok <- authorize_attachment(attachment, subject) do
      {:ok, Projector.attachment(attachment)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Lists message-owned files visible to an active human subject.

  The query is contained by ConversationContent, validates the current
  identity session before selecting tenant data, and limits the source
  conversations to active memberships. Archived, departed, deleted, and
  moderated sources are excluded. Unsafe files remain visible with their
  safety state but never expose storage identity.
  """
  @spec list_files(map(), map()) ::
          {:ok,
           %{
             files: [FileView.t()],
             limit: pos_integer(),
             has_more: boolean(),
             next_cursor: String.t() | nil
           }}
          | {:error,
             :forbidden
             | :invalid_file_scope
             | :invalid_conversation_id
             | :invalid_cursor}
  def list_files(subject, params \\ %{})

  def list_files(subject, params) when is_map(subject) and is_map(params) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, scope} <- file_scope(value(params, :scope)),
         {:ok, conversation_id} <- optional_file_conversation(value(params, :conversation_id)),
         {:ok, cursor} <- optional_file_cursor(value(params, :cursor)) do
      authorization_query = Conversations.active_membership_authorization_query(grant)

      with :ok <- authorize_file_conversation(conversation_id, grant) do
        limit = file_limit(value(params, :limit))

        results =
          from(attachment in Attachment,
            as: :attachment,
            join: message in "messages",
            as: :message,
            on:
              type(field(message, :id), :binary_id) == attachment.message_id and
                type(field(message, :tenant_id), :binary_id) == attachment.tenant_id,
            join: authorization in subquery(authorization_query),
            as: :conversation_authorization,
            on:
              authorization.conversation_id ==
                type(field(message, :conversation_id), :binary_id),
            where:
              attachment.tenant_id == ^grant.tenant_id and
                field(message, :status) == "active" and attachment.status != :deleted and
                not is_nil(attachment.message_id),
            order_by: [desc: field(message, :inserted_at), desc: attachment.id],
            select: %{
              attachment: attachment,
              conversation_id: type(field(message, :conversation_id), :binary_id),
              conversation_sequence: type(field(message, :conversation_sequence), :integer),
              shared_at: type(field(message, :inserted_at), :utc_datetime_usec)
            }
          )
          |> maybe_filter_file_scope(scope, grant.user_id)
          |> maybe_filter_file_conversation(conversation_id)
          |> maybe_before_file_cursor(cursor)
          |> limit(^(limit + 1))
          |> Repo.all()

        has_more = length(results) > limit
        files = results |> Enum.take(limit) |> Projector.files()

        {:ok,
         %{
           files: files,
           limit: limit,
           has_more: has_more,
           next_cursor: if(has_more, do: file_cursor_for(List.last(files)), else: nil)
         }}
      end
    end
  end

  def list_files(_subject, _params), do: {:error, :forbidden}

  def list_for_message(message_id) do
    Attachment
    |> where(
      [a],
      a.message_id == ^message_id and a.status == :ready and a.scan_status == :clean and
        not is_nil(a.object_version_id) and
        a.verified_checksum_sha256 == a.checksum_sha256
    )
    |> order_by([a], asc: a.inserted_at)
    |> Repo.all()
    |> Projector.attachments()
  end

  def list_safety(subject, opts \\ %{}) do
    with :ok <- authorize_safety(:list, subject) do
      limit = opts |> value(:limit) |> integer(50) |> min(100) |> max(1)
      status = normalize_scan_filter(value(opts, :scan_status))

      query =
        Attachment
        |> where([attachment], attachment.tenant_id == ^value(subject, :tenant_id))
        |> maybe_scan_filter(status)
        |> order_by([attachment], desc: attachment.inserted_at)
        |> limit(^limit)
        |> preload(:scan_attempt_records)

      {:ok, query |> Repo.all() |> Projector.attachments()}
    end
  end

  def claim_scan(id) when is_binary(id) do
    Repo.transaction(fn ->
      attachment = Repo.one(from(a in Attachment, where: a.id == ^id, lock: "FOR UPDATE"))

      cond do
        is_nil(attachment) ->
          Repo.rollback(:not_found)

        attachment.status == :ready and attachment.scan_status == :clean ->
          {:already_clean, attachment}

        claimable_scan?(attachment) ->
          token = Ecto.UUID.generate()

          attachment
          |> Attachment.changeset(%{
            scan_status: :scanning,
            scan_error_code: nil,
            scan_generation: attachment.scan_generation + 1,
            scan_claim_token: token,
            scan_claimed_at: now()
          })
          |> Repo.update!()

        true ->
          Repo.rollback(:not_claimable)
      end
    end)
    |> unwrap_transaction()
    |> project_claim_result()
  end

  def record_scan(%AttachmentView{} = attachment, result) do
    Repo.transaction(fn ->
      locked =
        Repo.one!(from(a in Attachment, where: a.id == ^attachment.id, lock: "FOR UPDATE"))

      unless current_scan_claim?(locked, attachment) do
        Repo.rollback(:stale_scan_claim)
      end

      completed_at = now()
      attempt_number = locked.scan_attempts + 1
      attrs = scan_attempt_attrs(locked, attempt_number, result, completed_at)

      %ScanAttempt{}
      |> ScanAttempt.changeset(attrs)
      |> Repo.insert!()

      locked
      |> Attachment.changeset(scan_result_attrs(result, attempt_number, completed_at))
      |> Repo.update!()
    end)
    |> unwrap_transaction()
    |> project_result()
  end

  def retry_scan(id, subject) do
    with :ok <- authorize_safety(:manage, subject) do
      Repo.transaction(fn ->
        attachment =
          Repo.one(
            from(a in Attachment,
              where: a.id == ^id and a.tenant_id == ^value(subject, :tenant_id),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        cond do
          attachment.status == :ready -> Repo.rollback(:already_clean)
          attachment.scan_status == :scanning -> Repo.rollback(:scan_in_progress)
          true -> :ok
        end

        updated = reset_scan!(attachment)

        case enqueue_scan(updated) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        audit!(subject, "attachment.scan_retried", updated.id, %{
          previous_status: attachment.scan_status
        })

        updated
      end)
      |> unwrap_transaction()
      |> project_result()
    end
  end

  def downloadable?(%AttachmentView{} = attachment) do
    attachment.status == :ready and attachment.scan_status == :clean and
      is_binary(attachment.object_version_id) and attachment.object_version_id != "" and
      is_binary(attachment.object_etag) and attachment.object_etag != "" and
      is_binary(attachment.verified_checksum_sha256) and
      attachment.verified_checksum_sha256 == attachment.checksum_sha256
  end

  @doc """
  Claims ready attachments for a message inside the caller's transaction.

  Messaging owns the surrounding message transaction; this contributed write
  refuses to run independently so the message and attachment claims cannot
  commit separately.
  """
  @spec attach_ready([String.t()], String.t(), String.t(), map()) ::
          :ok | {:error, :transaction_required}
  def attach_ready(ids, message_id, tenant_id, subject)
      when is_list(ids) and is_binary(message_id) and is_binary(tenant_id) do
    if Repo.in_transaction?() do
      attach_ready_in_transaction(Enum.uniq(ids), message_id, tenant_id, subject)
    else
      {:error, :transaction_required}
    end
  end

  defp attach_ready_in_transaction([], _message_id, _tenant_id, _subject), do: :ok

  defp attach_ready_in_transaction(ids, message_id, tenant_id, subject) do
    query =
      from(a in Attachment,
        where:
          a.id in ^ids and a.tenant_id == ^tenant_id and
            a.owner_user_id == ^value(subject, :user_id) and a.status == :ready and
            a.scan_status == :clean and not is_nil(a.object_version_id) and
            a.verified_checksum_sha256 == a.checksum_sha256 and is_nil(a.message_id)
      )

    {count, _} = Repo.update_all(query, set: [message_id: message_id, updated_at: now()])
    if count == length(ids), do: :ok, else: Repo.rollback(:invalid_attachments)
  end

  defp owned_for_update(id, subject) do
    Repo.one(
      from(attachment in Attachment,
        where:
          attachment.id == ^id and attachment.tenant_id == ^value(subject, :tenant_id) and
            attachment.owner_user_id == ^value(subject, :user_id),
        lock: "FOR UPDATE"
      )
    )
  end

  defp authorize_attachment(%Attachment{message_id: message_id} = attachment, subject)
       when is_binary(message_id),
       do: authorize_attached_message(attachment, subject)

  defp authorize_attachment(%Attachment{owner_user_id: owner_id}, subject) do
    if owner_id == value(subject, :user_id), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_attached_message(%Attachment{message_id: message_id}, subject)
       when is_binary(message_id) do
    conversation_id =
      Repo.one(
        from(message in "messages",
          where:
            message.id == type(^message_id, :binary_id) and
              message.tenant_id == type(^value(subject, :tenant_id), :binary_id),
          select: message.conversation_id
        )
      )

    if is_binary(conversation_id),
      do: Conversations.authorize_read(conversation_id, subject),
      else: {:error, :forbidden}
  end

  defp validate_type(type) do
    if type in @allowed_exact or Enum.any?(@allowed_prefixes, &String.starts_with?(type, &1)) do
      :ok
    else
      {:error, :unsupported_content_type}
    end
  end

  defp validate_size(size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size > 0 and size <= max_bytes,
       do: :ok

  defp validate_size(_, _), do: {:error, :invalid_attachment_size}

  defp validate_checksum(nil), do: {:error, :attachment_checksum_required}

  defp validate_checksum(checksum) when is_binary(checksum) do
    if Regex.match?(~r/^[a-f0-9]{64}$/, checksum),
      do: :ok,
      else: {:error, :invalid_attachment_checksum}
  end

  defp validate_checksum(_), do: {:error, :invalid_attachment_checksum}

  defp checksum_matches(%Attachment{checksum_sha256: checksum}, checksum), do: :ok
  defp checksum_matches(_attachment, _checksum), do: {:error, :attachment_checksum_mismatch}

  defp reset_scan!(attachment) do
    attachment
    |> Attachment.changeset(%{
      status: :uploaded,
      scan_status: :pending,
      scan_verdict: nil,
      scan_error_code: nil,
      quarantined_at: nil,
      scan_generation: attachment.scan_generation + 1,
      scan_claim_token: nil,
      scan_claimed_at: nil
    })
    |> Repo.update!()
  end

  defp enqueue_scan(%Attachment{} = attachment) do
    %{
      "attachment_id" => attachment.id,
      "tenant_id" => attachment.tenant_id,
      "dispatch_generation" => attachment.scan_generation
    }
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:attachment_scan),
      queue: :media,
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

  defp enqueue_abandon_cleanup!(%Attachment{cleanup_status: :complete}), do: :ok

  defp enqueue_abandon_cleanup!(%Attachment{} = attachment) do
    args = %{
      "attachment_id" => attachment.id,
      "tenant_id" => attachment.tenant_id
    }

    worker = RuntimePorts.job_worker_name!(:attachment_abandon)

    active_job? =
      Repo.exists?(
        from(job in Oban.Job,
          where:
            job.worker == ^worker and job.args == ^args and
              job.state in ["available", "scheduled", "executing", "retryable"]
        )
      )

    unless active_job? do
      args
      |> Oban.Job.new(
        worker: worker,
        queue: :media,
        scheduled_at: attachment.cleanup_next_attempt_at || current_cleanup_due_at(attachment),
        unique: [
          period: :infinity,
          fields: [:worker, :args],
          states: [:available, :scheduled, :executing, :retryable]
        ]
      )
      |> Repo.insert!()
    end

    :ok
  end

  defp cleanup_target(%Attachment{} = attachment) do
    %{
      id: attachment.id,
      tenant_id: attachment.tenant_id,
      object_key: attachment.object_key
    }
  end

  defp abandon_attachment!(
         %Attachment{status: :deleted, cleanup_status: cleanup_status} = attachment,
         _due_at
       )
       when cleanup_status != :not_required,
       do: attachment

  defp abandon_attachment!(%Attachment{} = attachment, due_at) do
    attachment
    |> Attachment.changeset(%{
      status: :deleted,
      scan_claim_token: nil,
      scan_claimed_at: nil,
      scan_generation:
        if(attachment.status == :deleted,
          do: attachment.scan_generation,
          else: attachment.scan_generation + 1
        ),
      cleanup_status: :scheduled,
      cleanup_next_attempt_at: due_at,
      cleanup_claimed_at: nil,
      cleanup_last_error: nil,
      cleanup_completed_at: nil
    })
    |> Repo.update!()
  end

  defp normalize_reconciled_cleanup!(
         %Attachment{cleanup_status: :running} = attachment,
         current
       ) do
    attachment
    |> Attachment.changeset(%{
      cleanup_status: :retryable,
      cleanup_next_attempt_at: current,
      cleanup_claimed_at: nil,
      cleanup_last_error: "cleanup_claim_stale",
      cleanup_completed_at: nil
    })
    |> Repo.update!()
  end

  defp normalize_reconciled_cleanup!(
         %Attachment{cleanup_status: :not_required} = attachment,
         current
       ) do
    abandon_attachment!(attachment, current)
  end

  defp normalize_reconciled_cleanup!(%Attachment{} = attachment, _current), do: attachment

  defp cleanup_due_in(%Attachment{} = attachment, current) do
    required_at =
      case attachment.upload_expires_at do
        %DateTime{} = expires_at ->
          later_datetime(
            attachment.cleanup_next_attempt_at,
            DateTime.add(expires_at, cleanup_grace_seconds(), :second)
          )

        nil ->
          attachment.cleanup_next_attempt_at
      end

    if match?(%DateTime{}, required_at) and DateTime.compare(required_at, current) == :gt do
      max(DateTime.diff(required_at, current, :second), 1)
    end
  end

  defp current_cleanup_due_at(%Attachment{upload_expires_at: %DateTime{} = expires_at}),
    do: DateTime.add(expires_at, cleanup_grace_seconds(), :second)

  defp current_cleanup_due_at(%Attachment{}), do: now()

  defp later_datetime(nil, %DateTime{} = right), do: right

  defp later_datetime(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp cleanup_retry_delay_seconds(attempts) when is_integer(attempts) and attempts > 0 do
    delays = [30, 60, 120, 300, 600, 1_200, 1_800, 3_600]
    Enum.at(delays, min(attempts - 1, length(delays) - 1))
  end

  defp cleanup_retry_delay_seconds(_attempts), do: 30

  defp cleanup_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp cleanup_error({kind, status}) when is_atom(kind) and is_integer(status),
    do: "#{kind}:#{status}"

  defp cleanup_error(_reason), do: "attachment_cleanup_failed"

  defp cleanup_grace_seconds do
    Application.get_env(
      :comms_core,
      :attachment_cleanup_grace_seconds,
      @default_cleanup_grace_seconds
    )
  end

  defp cleanup_claim_timeout_seconds do
    Application.get_env(
      :comms_core,
      :attachment_cleanup_claim_timeout_seconds,
      @default_cleanup_claim_timeout_seconds
    )
  end

  defp cleanup_reconcile_limit do
    :comms_core
    |> Application.get_env(:attachment_cleanup_reconcile_limit, @default_cleanup_reconcile_limit)
    |> max(1)
    |> min(1_000)
  end

  defp maybe_enqueue_scan(%Attachment{scan_status: status}) when status in [:clean, :blocked],
    do: :ok

  defp maybe_enqueue_scan(attachment), do: enqueue_scan(attachment)

  defp claimable_scan?(attachment) do
    stale =
      is_nil(attachment.scan_claimed_at) or
        DateTime.diff(now(), attachment.scan_claimed_at, :second) >= @scan_claim_timeout_seconds

    attachment.status in [:uploaded, :scan_failed] and
      (attachment.scan_status in [:pending, :failed] or
         (attachment.scan_status == :scanning and stale))
  end

  defp scan_attempt_attrs(attachment, attempt_number, result, completed_at) do
    metadata = scan_metadata(result)

    %{
      tenant_id: attachment.tenant_id,
      attachment_id: attachment.id,
      attempt_number: attempt_number,
      provider: metadata.provider,
      status: scan_attempt_status(result),
      verdict: metadata.verdict,
      error_code: metadata.error_code,
      provider_reference: metadata.provider_reference,
      started_at: attachment.scan_claimed_at || completed_at,
      completed_at: completed_at
    }
  end

  defp scan_result_attrs(result, attempt_number, completed_at) do
    metadata = scan_metadata(result)

    case scan_attempt_status(result) do
      :clean ->
        %{
          status: :ready,
          scan_status: :clean,
          scan_verdict: metadata.verdict || "clean",
          scan_provider: metadata.provider,
          scan_attempts: attempt_number,
          scan_error_code: nil,
          scanned_at: completed_at,
          quarantined_at: nil,
          scan_claim_token: nil,
          scan_claimed_at: nil
        }

      :blocked ->
        %{
          status: :quarantined,
          scan_status: :blocked,
          scan_verdict: metadata.verdict || "blocked",
          scan_provider: metadata.provider,
          scan_attempts: attempt_number,
          scan_error_code: nil,
          scanned_at: completed_at,
          quarantined_at: completed_at,
          scan_claim_token: nil,
          scan_claimed_at: nil
        }

      _ ->
        %{
          status: :scan_failed,
          scan_status: :failed,
          scan_verdict: nil,
          scan_provider: metadata.provider,
          scan_attempts: attempt_number,
          scan_error_code: metadata.error_code,
          scanned_at: completed_at,
          quarantined_at: completed_at,
          scan_claim_token: nil,
          scan_claimed_at: nil
        }
    end
  end

  defp scan_attempt_status({:ok, metadata}) when is_map(metadata) do
    case value(metadata, :verdict) do
      verdict when verdict in [:clean, "clean"] ->
        :clean

      verdict
      when verdict in [:malicious, "malicious", :suspicious, "suspicious", :blocked, "blocked"] ->
        :blocked

      _ ->
        :failed
    end
  end

  defp scan_attempt_status({:error, :permanent, _}), do: :failed
  defp scan_attempt_status({:error, _}), do: :retryable
  defp scan_attempt_status(_), do: :failed

  defp scan_metadata({:ok, metadata}) when is_map(metadata) do
    %{
      provider: safe_text(value(metadata, :provider), "configured"),
      verdict: safe_text(value(metadata, :verdict), nil),
      provider_reference: safe_text(value(metadata, :provider_reference), nil),
      error_code: nil
    }
  end

  defp scan_metadata({:error, :permanent, reason}), do: scan_error_metadata(reason)
  defp scan_metadata({:error, reason}), do: scan_error_metadata(reason)
  defp scan_metadata(_), do: scan_error_metadata(:invalid_scanner_response)

  defp scan_error_metadata(reason) do
    %{
      provider: "configured",
      verdict: nil,
      provider_reference: nil,
      error_code: safe_error_code(reason)
    }
  end

  defp safe_error_code({kind, status}) when is_atom(kind) and is_integer(status),
    do: "#{kind}_#{status}"

  defp safe_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_code(_), do: "scanner_error"
  defp safe_text(value, _fallback) when is_atom(value), do: Atom.to_string(value)
  defp safe_text(value, _fallback) when is_binary(value), do: String.slice(value, 0, 255)
  defp safe_text(_, fallback), do: fallback

  defp normalize_scan_filter(value)
       when value in [:pending, :scanning, :clean, :blocked, :failed],
       do: value

  defp normalize_scan_filter(value) when is_binary(value) do
    case value do
      "pending" -> :pending
      "scanning" -> :scanning
      "clean" -> :clean
      "blocked" -> :blocked
      "failed" -> :failed
      _ -> nil
    end
  end

  defp normalize_scan_filter(_), do: nil
  defp maybe_scan_filter(query, nil), do: query

  defp maybe_scan_filter(query, status),
    do: where(query, [attachment], attachment.scan_status == ^status)

  defp file_scope(nil), do: {:ok, :recent}
  defp file_scope(""), do: {:ok, :recent}
  defp file_scope(:recent), do: {:ok, :recent}
  defp file_scope("recent"), do: {:ok, :recent}
  defp file_scope(:shared_by_me), do: {:ok, :shared_by_me}
  defp file_scope("shared_by_me"), do: {:ok, :shared_by_me}
  defp file_scope(_value), do: {:error, :invalid_file_scope}

  defp optional_file_conversation(nil), do: {:ok, nil}
  defp optional_file_conversation(""), do: {:ok, nil}

  defp optional_file_conversation(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, conversation_id} -> {:ok, conversation_id}
      :error -> {:error, :invalid_conversation_id}
    end
  end

  defp optional_file_conversation(_value), do: {:error, :invalid_conversation_id}

  defp authorize_file_conversation(nil, _grant), do: :ok

  defp authorize_file_conversation(conversation_id, grant) do
    if Conversations.active_conversation_member?(grant, conversation_id),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp maybe_filter_file_scope(query, :recent, _user_id), do: query

  defp maybe_filter_file_scope(query, :shared_by_me, user_id),
    do: where(query, [attachment: attachment], attachment.owner_user_id == ^user_id)

  defp maybe_filter_file_conversation(query, nil), do: query

  defp maybe_filter_file_conversation(query, conversation_id),
    do:
      where(
        query,
        [message: message],
        type(field(message, :conversation_id), :binary_id) == ^conversation_id
      )

  defp optional_file_cursor(nil), do: {:ok, nil}
  defp optional_file_cursor(""), do: {:ok, nil}

  defp optional_file_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"shared_at" => shared_at, "id" => id, "v" => 1}} <- Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(shared_at),
         {:ok, attachment_id} <- Ecto.UUID.cast(id) do
      {:ok, {DateTime.truncate(timestamp, :microsecond), attachment_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_file_cursor(_value), do: {:error, :invalid_cursor}

  defp maybe_before_file_cursor(query, nil), do: query

  defp maybe_before_file_cursor(query, {timestamp, attachment_id}) do
    where(
      query,
      [attachment: attachment, message: message],
      type(field(message, :inserted_at), :utc_datetime_usec) < ^timestamp or
        (type(field(message, :inserted_at), :utc_datetime_usec) == ^timestamp and
           attachment.id < ^attachment_id)
    )
  end

  defp file_cursor_for(nil), do: nil

  defp file_cursor_for(%FileView{} = file) do
    %{v: 1, shared_at: DateTime.to_iso8601(file.shared_at), id: file.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp file_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_file_limit)

  defp file_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> file_limit(number)
      _ -> @default_file_limit
    end
  end

  defp file_limit(_value), do: @default_file_limit

  defp authorize_safety(mode, subject) when mode in [:list, :manage] do
    action = if mode == :list, do: :administer_tenant, else: :manage_attachment_safety

    case Accounts.access_grant(subject) do
      {:ok, %{role: role} = grant} when role in [:owner, :admin] ->
        if mode == :list or Map.get(grant, :step_up_recent?, false) do
          :ok
        else
          deny_privileged(action, subject, :step_up_required)
        end

      _ ->
        deny_privileged(action, subject, :forbidden)
    end
  end

  defp deny_privileged(action, subject, reason) do
    Accounts.audit_authorization_denial(action, subject, reason)
  end

  defp audit!(subject, action, resource_id, metadata) do
    Audit.record(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: "attachment",
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp normalize_checksum(nil), do: nil

  defp normalize_checksum(checksum) when is_binary(checksum),
    do: checksum |> String.trim() |> String.downcase()

  defp normalize_checksum(_), do: :invalid

  defp validate_identity(identity, checksum) when is_map(identity) do
    version = value(identity, :object_version_id)
    etag = value(identity, :object_etag)
    verified_checksum = normalize_checksum(value(identity, :verified_checksum_sha256))

    if is_binary(version) and version not in ["", "null"] and is_binary(etag) and etag != "" and
         verified_checksum == checksum do
      {:ok,
       %{
         object_version_id: String.slice(version, 0, 1_024),
         object_etag: String.slice(etag, 0, 255),
         verified_checksum_sha256: verified_checksum
       }}
    else
      {:error, :object_identity_invalid}
    end
  end

  defp validate_identity(_, _), do: {:error, :object_identity_invalid}

  defp current_scan_claim?(locked, claimed) do
    locked.scan_status == :scanning and is_binary(claimed.scan_claim_token) and
      locked.scan_claim_token == claimed.scan_claim_token and
      locked.scan_generation == claimed.scan_generation
  end

  defp attachment_limit(subject) do
    case Administration.conversation_content_policy(subject) do
      {:ok, %Administration.ConversationContentPolicy{max_attachment_bytes: limit}}
      when is_integer(limit) and limit > 0 and limit <= @schema_max_bytes ->
        {:ok, limit}

      {:ok, _policy} ->
        {:ok, @default_max_bytes}

      {:error, _reason} = error ->
        error
    end
  end

  defp sanitize_file_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
    |> String.slice(0, 255)
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp project_result({:ok, %Attachment{} = attachment}),
    do: {:ok, Projector.attachment(attachment)}

  defp project_result({:error, reason}), do: {:error, reason}

  defp project_claim_result({:ok, {:already_clean, %Attachment{} = attachment}}),
    do: {:ok, {:already_clean, Projector.attachment(attachment)}}

  defp project_claim_result({:ok, %Attachment{} = attachment}),
    do: {:ok, Projector.attachment(attachment)}

  defp project_claim_result({:error, reason}), do: {:error, reason}

  defp validate_erasure_scope(tenant_id, ids) do
    if valid_uuid?(tenant_id) and Enum.all?(ids, &valid_uuid?/1),
      do: :ok,
      else: {:error, :invalid_erasure_scope}
  end

  defp erasure_scope_filter(query, [], nil), do: where(query, [attachment], false)

  defp erasure_scope_filter(query, message_ids, nil),
    do: where(query, [attachment], attachment.message_id in ^message_ids)

  defp erasure_scope_filter(query, [], owner_user_id),
    do: where(query, [attachment], attachment.owner_user_id == ^owner_user_id)

  defp erasure_scope_filter(query, message_ids, owner_user_id) do
    where(
      query,
      [attachment],
      attachment.message_id in ^message_ids or attachment.owner_user_id == ^owner_user_id
    )
  end

  defp cast_uuid_list(values) do
    values
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, ids} ->
      case Ecto.UUID.cast(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  defp cast_optional_uuid(nil), do: {:ok, nil}
  defp cast_optional_uuid(value), do: Ecto.UUID.cast(value)

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
