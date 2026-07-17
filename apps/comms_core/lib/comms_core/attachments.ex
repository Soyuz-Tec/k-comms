defmodule CommsCore.Attachments do
  import Ecto.Query

  alias CommsCore.{Authorization, Repo, RuntimePorts}
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Attachments.{Attachment, AttachmentView, Projector, ScanAttempt}
  alias CommsCore.Audit

  @allowed_prefixes ["image/", "text/"]
  @allowed_exact ["application/pdf", "application/zip", "application/json"]
  @default_max_bytes 26_214_400
  @schema_max_bytes 1_073_741_824
  @scan_claim_timeout_seconds 300

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
    max_bytes = attachment_limit(value(subject, :tenant_id))

    with :ok <- validate_type(content_type),
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
          if attachment.status == :pending do
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
          else
            attachment
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
    with :ok <- Authorization.authorize(:administer_tenant, subject, %{}) do
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
    with :ok <- Authorization.authorize(:manage_attachment_safety, subject, %{}) do
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

  def attach_ready(ids, message_id, tenant_id, subject)
      when is_list(ids) and is_binary(message_id) and is_binary(tenant_id) do
    ids = Enum.uniq(ids)

    if ids == [] do
      :ok
    else
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

  defp authorize_attachment(%Attachment{owner_user_id: owner_id} = attachment, subject) do
    if owner_id == value(subject, :user_id) do
      :ok
    else
      authorize_attached_message(attachment, subject)
    end
  end

  defp authorize_attached_message(%Attachment{message_id: message_id}, subject)
       when is_binary(message_id) do
    message =
      Repo.one(
        from(message in "messages",
          where:
            message.id == type(^message_id, :binary_id) and
              message.tenant_id == type(^value(subject, :tenant_id), :binary_id),
          select: %{
            id: message.id,
            tenant_id: message.tenant_id,
            conversation_id: message.conversation_id
          }
        )
      )

    case message do
      %{conversation_id: _conversation_id} ->
        Authorization.authorize(:read_conversation, subject, message)

      nil ->
        {:error, :forbidden}
    end
  end

  defp authorize_attached_message(_, _), do: {:error, :forbidden}

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

  defp maybe_enqueue_scan(%Attachment{scan_status: status}) when status in [:clean, :blocked],
    do: :ok

  defp maybe_enqueue_scan(attachment), do: enqueue_scan(attachment)

  defp claimable_scan?(attachment) do
    stale =
      is_nil(attachment.scan_claimed_at) or
        DateTime.diff(now(), attachment.scan_claimed_at, :second) >= @scan_claim_timeout_seconds

    attachment.scan_status in [:pending, :failed] or
      (attachment.scan_status == :scanning and stale)
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

  defp attachment_limit(tenant_id) do
    case Repo.get_by(TenantSettings, tenant_id: tenant_id) do
      %TenantSettings{max_attachment_bytes: limit}
      when is_integer(limit) and limit > 0 and limit <= @schema_max_bytes ->
        limit

      _ ->
        @default_max_bytes
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

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
