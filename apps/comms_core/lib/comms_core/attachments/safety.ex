defmodule CommsCore.Attachments.Safety do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo, RuntimePorts}
  alias CommsCore.Audit
  alias CommsCore.Attachments.{Attachment, AttachmentView, Projector, ScanAttempt}

  @scan_claim_timeout_seconds 300

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

  @doc false
  def enqueue_scan(%Attachment{} = attachment) do
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

  defp current_scan_claim?(locked, claimed) do
    locked.scan_status == :scanning and is_binary(claimed.scan_claim_token) and
      locked.scan_claim_token == claimed.scan_claim_token and
      locked.scan_generation == claimed.scan_generation
  end

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

  defp project_result({:ok, %Attachment{} = attachment}),
    do: {:ok, Projector.attachment(attachment)}

  defp project_result({:error, reason}), do: {:error, reason}

  defp project_claim_result({:ok, {:already_clean, %Attachment{} = attachment}}),
    do: {:ok, {:already_clean, Projector.attachment(attachment)}}

  defp project_claim_result({:ok, %Attachment{} = attachment}),
    do: {:ok, Projector.attachment(attachment)}

  defp project_claim_result({:error, reason}), do: {:error, reason}

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
