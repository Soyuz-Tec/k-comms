defmodule CommsCore.Attachments.Abandonment do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Repo, RuntimePorts}
  alias CommsCore.Audit
  alias CommsCore.Attachments.{Attachment, AttachmentVariant, AttachmentView, Projector}

  @max_upload_ttl_seconds 3_600
  @default_cleanup_grace_seconds 300
  @default_cleanup_claim_timeout_seconds 900
  @default_cleanup_reconcile_limit 100

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
      object_key: attachment.object_key,
      variant_object_keys: variant_object_keys(attachment)
    }
  end

  defp variant_object_keys(%Attachment{} = attachment) do
    Repo.all(
      from(variant in AttachmentVariant,
        where:
          variant.attachment_id == ^attachment.id and
            variant.tenant_id == ^attachment.tenant_id,
        order_by: [asc: variant.kind],
        select: variant.object_key
      )
    )
  end

  # Deletion is per object version, so each variant contributes its own key and
  # version rather than being reachable through the attachment's key.

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

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp project_result({:ok, %Attachment{} = attachment}),
    do: {:ok, Projector.attachment(attachment)}

  defp project_result({:error, reason}), do: {:error, reason}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
