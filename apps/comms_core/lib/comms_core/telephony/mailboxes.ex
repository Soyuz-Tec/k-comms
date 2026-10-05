defmodule CommsCore.Telephony.Mailboxes do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Administration, Audit, Repo, RuntimePorts, ValidationError}
  alias CommsCore.Accounts.AccessGrant
  @worker_transaction_budget_ms 150_000
  @effect_commit_margin_ms 10_000

  alias CommsCore.Telephony.{
    Call,
    Mailbox,
    Number,
    ProviderControlPort,
    Route,
    Voicemail,
    VoicemailErasurePlan,
    VoicemailObject,
    VoicemailRead,
    VoicemailRequest,
    VoicemailProtectionPort,
    VoicemailProviderPort,
    VoicemailStoragePort
  }

  @doc false
  @spec rollback_voicemail_hazard_count() :: non_neg_integer()
  def rollback_voicemail_hazard_count() do
    reads = from(r in VoicemailRead, select: r.voicemail_id)

    Repo.aggregate(
      from(v in Voicemail,
        where:
          v.status != :deleted or is_nil(v.erasure_verified_at) or
            is_nil(v.provider_deleted_at) or is_nil(v.deleted_at) or
            v.id in subquery(reads)
      ),
      :count
    )
  end

  def config(subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, grant} <- access(subject) do
      {:ok, %{mailbox: visible_box(Repo.get_by(Mailbox, tenant_id: grant.tenant_id))}}
    end
  end

  def save(attrs, subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, grant} <- access(subject),
         reason when is_binary(reason) and byte_size(reason) in 3..500 <- value(attrs, :reason),
         {:ok, user_id} <- Ecto.UUID.cast(value(attrs, :user_id)) do
      Repo.transaction(fn ->
        # Mailbox reassignment shares the tenant policy fence with capture and
        # erasure so its current owner cannot change during a hold projection.
        protection!(grant.tenant_id, [])

        with {:ok, _} <- Administration.lock_call_policy(grant.tenant_id),
             {:ok, [_]} <- Accounts.lock_active_human_directory_users(grant.tenant_id, [user_id]),
             {:ok, %AccessGrant{role: role, step_up_recent?: true} = locked} <-
               Accounts.lock_access_grant(subject),
             true <- role in [:owner, :admin] do
          number = Repo.get_by(Number, tenant_id: grant.tenant_id)
          if is_nil(number), do: Repo.rollback(:telephony_not_configured)

          box =
            Repo.one(from(b in Mailbox, where: b.number_id == ^number.id, lock: "FOR UPDATE")) ||
              %Mailbox{}

          if box.id && value(attrs, :version) != box.version, do: Repo.rollback(:stale_version)

          if value(attrs, :enabled) == true and not ready?(),
            do: Repo.rollback(:telephony_voicemail_unavailable)

          parameters = %{
            tenant_id: grant.tenant_id,
            number_id: number.id,
            user_id: user_id,
            enabled: value(attrs, :enabled),
            retention_days: value(attrs, :retention_days),
            notice_media: value(attrs, :notice_media),
            version: (box.version || 0) + 1
          }

          case box |> Mailbox.changeset(parameters) |> Repo.insert_or_update() do
            {:ok, saved} ->
              case Audit.record(%{
                     tenant_id: grant.tenant_id,
                     actor_user_id: locked.user_id,
                     action: "telephony.mailbox.saved",
                     resource_type: "telephony_mailbox",
                     resource_id: saved.id,
                     metadata: %{reason: reason, version: saved.version}
                   }) do
                {:ok, _} -> :ok
                _ -> Repo.rollback(:audit_failed)
              end

              visible_box(saved)

            {:error, changeset} ->
              {:ok, error} = ValidationError.from(changeset)
              Repo.rollback(error)
          end
        else
          {:ok, %AccessGrant{step_up_recent?: false}} -> Repo.rollback(:step_up_required)
          _ -> Repo.rollback(:forbidden)
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_telephony_mailbox}
    end
  end

  # Called from the owning telephone-control transaction before recording starts.
  def reserve!(call) do
    lock_capture_effect_policy!(call)

    box =
      Repo.one(
        from(b in Mailbox,
          where:
            b.tenant_id == ^call.tenant_id and b.number_id == ^call.number_id and
              b.enabled == true,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(box), do: Repo.rollback(:telephony_mailbox_unavailable)
    if not ready?(), do: Repo.rollback(:telephony_voicemail_unavailable)

    case Accounts.lock_active_human_directory_users(call.tenant_id, [box.user_id]) do
      {:ok, [_]} -> :ok
      _ -> Repo.rollback(:telephony_mailbox_unavailable)
    end

    subjects = [box.user_id, call.user_id] |> Enum.reject(&is_nil/1) |> Enum.uniq()
    protection = protection!(call.tenant_id, subjects)
    if protection.capture_blocked, do: Repo.rollback(:voicemail_capture_cancelled)
    timestamp = DateTime.utc_now()

    live =
      Repo.aggregate(
        from(v in Voicemail, where: v.mailbox_id == ^box.id and v.status != :deleted),
        :count
      )

    message = Repo.get_by(Voicemail, call_id: call.id)
    if is_nil(message) and live >= 500, do: Repo.rollback(:telephony_mailbox_full)

    if message && (message.status != :pending or not is_nil(message.erasure_requested_at)),
      do: Repo.rollback(:telephony_mailbox_unavailable)

    message =
      message ||
        %Voicemail{}
        |> Voicemail.changeset(%{
          tenant_id: call.tenant_id,
          mailbox_id: box.id,
          call_id: call.id,
          user_id: box.user_id,
          protected_user_ids: subjects,
          recording_name: "kc_vm_" <> String.replace(call.id, "-", ""),
          notice_media: box.notice_media,
          recording_deadline: DateTime.add(timestamp, 180, :second),
          retention_expires_at:
            DateTime.add(
              timestamp,
              max(box.retention_days, protection.retention_days) * 86_400,
              :second
            )
        })
        |> Repo.insert!()

    if is_nil(message.object_key),
      do:
        message
        |> Voicemail.changeset(%{object_key: VoicemailObject.key(message.tenant_id, message.id)})
        |> Repo.update!()

    CommsCore.Telephony.CallMonitor.enqueue_capture_monitor!(call, message.recording_deadline)
    enqueue!(message.id, DateTime.add(timestamp, 5, :second), :reconcile)
    enqueue!(message.id, message.retention_expires_at, :retention)
    message.notice_media
  end

  @doc false
  @spec capture_lifecycle(%Call{}) :: {:pending, DateTime.t()} | :complete | :absent
  def capture_lifecycle(%Call{} = call) do
    case Repo.get_by(Voicemail, tenant_id: call.tenant_id, call_id: call.id) do
      nil ->
        :absent

      %Voicemail{} = v ->
        bindings = call.pbx_state || %{}
        bound = map_size(bindings) == 0 or bindings["recording"] == v.recording_name
        expected_name = "kc_vm_" <> String.replace(call.id, "-", "")

        if v.status == :pending and is_nil(v.erasure_requested_at) and
             v.recording_name == expected_name and bound do
          deadline =
            if DateTime.compare(call.expires_at, v.recording_deadline) == :lt,
              do: call.expires_at,
              else: v.recording_deadline

          {:pending, deadline}
        else
          :complete
        end
    end
  end

  def notice_for_call(call_id) do
    case Repo.get_by(Voicemail, call_id: call_id) do
      %Voicemail{notice_media: notice} -> notice
      _ -> nil
    end
  end

  def ready? do
    get_in(ProviderControlPort.capabilities(), [:voicemail, :supported]) == true and
      VoicemailProviderPort.ready?() and VoicemailStoragePort.ready?()
  end

  def list(subject, params) do
    with {:ok, grant} <- access(subject),
         {:ok, limit} <- limit(value(params, :limit)),
         {:ok, cursor} <- cursor(value(params, :cursor), grant) do
      timestamp = DateTime.utc_now()
      base = visible_query(grant)

      base =
        from(v in base,
          where:
            v.status in [:pending, :available, :deleting, :failed] and
              v.retention_expires_at > ^timestamp
        )

      base =
        if cursor,
          do:
            from(v in base,
              where:
                v.inserted_at < ^cursor.inserted_at or
                  (v.inserted_at == ^cursor.inserted_at and v.id < ^cursor.id)
            ),
          else: base

      rows =
        Repo.all(
          from(v in base, order_by: [desc: v.inserted_at, desc: v.id], limit: ^(limit + 1))
        )

      messages = Enum.take(rows, limit)

      reads =
        Repo.all(
          from(r in VoicemailRead,
            where:
              r.tenant_id == ^grant.tenant_id and r.user_id == ^grant.user_id and
                r.voicemail_id in ^Enum.map(messages, & &1.id),
            select: {r.voicemail_id, r.read_at}
          )
        )
        |> Map.new()

      more = length(rows) > limit

      {:ok,
       %{
         messages: Enum.map(messages, &view(&1, reads[&1.id])),
         limit: limit,
         has_more: more,
         next_cursor: if(more, do: List.last(messages).id, else: nil),
         configured: ready?()
       }}
    end
  end

  def playback(id, subject) do
    with {:ok, _} <- access(subject), {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        protection!(value(subject, :tenant_id), [])
        grant = locked_access!(subject)
        v = locked_visible!(id, grant)

        if is_nil(v) or v.status != :available or
             DateTime.compare(v.retention_expires_at, DateTime.utc_now()) != :gt,
           do: Repo.rollback(:not_found)

        if protection!(v.tenant_id, protected_subjects(v)).capture_blocked,
          do: Repo.rollback(:not_found)

        case VoicemailStoragePort.download(object(v)) do
          {:ok, signed} -> signed
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :forbidden} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def mark_read(id, subject) do
    with {:ok, _} <- access(subject), {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        protection!(value(subject, :tenant_id), [])
        grant = locked_access!(subject)
        v = locked_visible!(id, grant)

        if is_nil(v) or v.status != :available or
             DateTime.compare(v.retention_expires_at, DateTime.utc_now()) != :gt,
           do: Repo.rollback(:not_found)

        if protection!(v.tenant_id, protected_subjects(v)).capture_blocked,
          do: Repo.rollback(:not_found)

        now = DateTime.utc_now()

        %VoicemailRead{}
        |> VoicemailRead.changeset(%{
          tenant_id: grant.tenant_id,
          voicemail_id: id,
          user_id: grant.user_id,
          read_at: now
        })
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:voicemail_id, :user_id])

        view(v, Repo.get_by!(VoicemailRead, voicemail_id: id, user_id: grant.user_id).read_at)
      end)
    else
      {:error, :forbidden} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def delete(id, subject) do
    with {:ok, _} <- access(subject), {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        protection!(value(subject, :tenant_id), [])
        grant = locked_access!(subject)
        v = locked_visible!(id, grant)
        if is_nil(v), do: Repo.rollback(:not_found)

        if protection!(v.tenant_id, protected_subjects(v)).held,
          do: Repo.rollback(:voicemail_legal_hold)

        if v.status != :deleted do
          v |> Voicemail.changeset(%{status: :deleting}) |> Repo.update!()
          capture_changed!(v)
          enqueue!(v.id, DateTime.utc_now(), :delete)
          audit!(v, grant.user_id, "telephony.voicemail.delete_requested")
        end

        :deleting
      end)
    else
      {:error, :forbidden} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def claim(id, caller) do
    worker(id, caller, fn v ->
      expired = DateTime.compare(v.retention_expires_at, DateTime.utc_now()) != :gt

      cond do
        v.status == :deleted ->
          :complete

        expired or v.status == :deleting ->
          if protection!(v.tenant_id, protected_subjects(v)).held,
            do: :held,
            else: request(v, :delete)

        v.status == :available and is_nil(v.provider_deleted_at) ->
          request(v, :delete_source)

        v.status in [:available, :failed] ->
          :complete

        true ->
          request(v, :reconcile)
      end
    end)
  end

  # Holding the source row across upload and metadata commit serializes ingestion
  # with deletion. A claimed worker can never upload after a completed purge.
  def store(id, media, caller) do
    worker(
      id,
      caller,
      fn v ->
        cond do
          not is_nil(v.erasure_requested_at) or
              protection!(v.tenant_id, protected_subjects(v)).capture_blocked ->
            Repo.rollback(:voicemail_capture_cancelled)

          v.status == :available ->
            :available

          v.status != :pending ->
            Repo.rollback(:voicemail_capture_cancelled)

          true ->
            with %{
                   body: body,
                   duration_seconds: seconds,
                   recording_name: name,
                   content_type: "audio/wav"
                 } <- media,
                 true <-
                   name == v.recording_name and is_binary(body) and
                     byte_size(body) in 1..8_388_608 and
                     is_integer(seconds) and seconds in 1..120,
                 {:ok, stored} <- VoicemailStoragePort.ingest(object(v), body),
                 {:ok, result} <-
                   complete(id, {:ok, %{object: stored, duration_seconds: seconds}}, caller) do
              result
            else
              {:error, reason} -> Repo.rollback(reason)
              _ -> Repo.rollback(:invalid_voicemail_media)
            end
        end
      end,
      30000
    )
  end

  def complete(id, result, caller) do
    worker(id, caller, fn v ->
      if not is_nil(v.erasure_requested_at) or
           protection!(v.tenant_id, protected_subjects(v)).capture_blocked,
         do: Repo.rollback(:voicemail_capture_cancelled)

      case result do
        {:ok, %{object: %VoicemailObject{} = stored, duration_seconds: seconds}}
        when is_integer(seconds) and seconds in 1..120 ->
          if not VoicemailObject.verified?(stored) or stored.tenant_id != v.tenant_id or
               stored.voicemail_id != v.id or stored.object_key != v.object_key,
             do: Repo.rollback(:voicemail_storage_identity_invalid)

          attrs =
            Map.from_struct(stored)
            |> Map.take([
              :object_key,
              :object_version_id,
              :object_etag,
              :checksum_sha256,
              :verified_checksum_sha256,
              :byte_size,
              :content_type
            ])

          cond do
            v.status == :deleted ->
              Repo.rollback(:voicemail_already_deleted)

            v.status == :available ->
              if v.object_version_id == stored.object_version_id and
                   v.checksum_sha256 == stored.checksum_sha256,
                 do: :available,
                 else: Repo.rollback(:voicemail_storage_identity_invalid)

            v.status == :pending ->
              v
              |> Voicemail.changeset(
                Map.merge(attrs, %{
                  status: :available,
                  duration_seconds: seconds,
                  available_at: DateTime.utc_now()
                })
              )
              |> Repo.update!()

              capture_changed!(v)
              audit!(v, nil, "telephony.voicemail.available")
              :available

            v.status == :deleting ->
              v |> Voicemail.changeset(attrs) |> Repo.update!()
              enqueue!(v.id, DateTime.utc_now(), :delete)
              :deleting
          end

        {:error, :not_found} when v.status == :pending ->
          if DateTime.compare(v.recording_deadline, DateTime.utc_now()) != :gt do
            v |> Voicemail.changeset(%{status: :deleting}) |> Repo.update!()
            capture_changed!(v)
            enqueue!(v.id, DateTime.utc_now(), :delete)
            :deleting
          else
            :pending
          end

        _ ->
          :pending
      end
    end)
  end

  def cleanup_source(id, caller) do
    worker(
      id,
      caller,
      fn v ->
        cond do
          not is_nil(v.provider_deleted_at) ->
            :complete

          v.status != :available ->
            :complete

          protection!(v.tenant_id, protected_subjects(v)).held ->
            :held

          true ->
            case VoicemailProviderPort.delete(request(v, :delete)) do
              :ok ->
                v
                |> Voicemail.changeset(%{provider_deleted_at: DateTime.utc_now()})
                |> Repo.update!()

                :complete

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end,
      20000
    )
  end

  # Provider and approved-object erasure happen under the same governance tenant
  # lock as hold creation. A hold cannot race the external effect after a claim.
  def purge(id, caller) do
    worker(
      id,
      caller,
      fn v ->
        cond do
          protection!(v.tenant_id, protected_subjects(v)).held ->
            :held

          v.status == :deleted and not is_nil(v.erasure_verified_at) ->
            delete_reads!(v)
            :deleted

          v.status == :deleting or (v.status == :deleted and is_nil(v.erasure_verified_at)) or
              DateTime.compare(v.retention_expires_at, DateTime.utc_now()) != :gt ->
            with :ok <- VoicemailProviderPort.delete(request(v, :delete)),
                 :ok <- VoicemailStoragePort.delete(object(v)) do
              v
              |> Voicemail.changeset(%{
                status: :deleted,
                deleted_at: DateTime.utc_now(),
                provider_deleted_at: DateTime.utc_now(),
                erasure_verified_at: DateTime.utc_now()
              })
              |> Repo.update!()

              delete_reads!(v)
              audit!(v, nil, "telephony.voicemail.deleted")
              :deleted
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          true ->
            Repo.rollback(:voicemail_not_deletable)
        end
      end,
      80000
    )
  end

  defp worker(id, caller, f, effect_budget_ms \\ 0) do
    if RuntimePorts.authorized_job_worker?(:telephony_voicemail, caller) and
         match?({:ok, _}, Ecto.UUID.cast(id)) do
      started_at = System.monotonic_time(:millisecond)

      Repo.transaction(
        fn ->
          snapshot = Repo.get(Voicemail, id)
          if is_nil(snapshot), do: Repo.rollback(:not_found)
          # Match governance preparation and call-control effects: tenant policy,
          # then authoritative call, then voicemail. Never invert this order.
          protection!(snapshot.tenant_id, [])
          lock_call!(snapshot.tenant_id, snapshot.call_id)

          case Repo.one(
                 from(v in Voicemail,
                   where: v.id == ^id and v.tenant_id == ^snapshot.tenant_id,
                   lock: "FOR UPDATE"
                 )
               ) do
            %Voicemail{} = v ->
              remaining =
                @worker_transaction_budget_ms - (System.monotonic_time(:millisecond) - started_at)

              if effect_budget_ms > 0 and remaining < effect_budget_ms + @effect_commit_margin_ms,
                do: Repo.rollback(:voicemail_effect_budget_unavailable)

              f.(v)

            _ ->
              Repo.rollback(:not_found)
          end
        end,
        timeout: @worker_transaction_budget_ms
      )
    else
      {:error, :forbidden}
    end
  end

  def lock_capture_effect_policy!(%Call{} = call) do
    protection!(call.tenant_id, [])
    :ok
  end

  def assert_capture_effect_allowed!(%Call{} = call) do
    v =
      Repo.one(
        from(v in Voicemail,
          where: v.tenant_id == ^call.tenant_id and v.call_id == ^call.id,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(v) or v.status != :pending or not is_nil(v.erasure_requested_at),
      do: Repo.rollback(:voicemail_capture_cancelled)

    if protection!(call.tenant_id, protected_subjects(v, call)).capture_blocked,
      do: Repo.rollback(:voicemail_capture_cancelled)

    :ok
  end

  @spec prepare_governance_erasure(String.t(), :user | :conversation | :message, String.t()) ::
          {:ok, VoicemailErasurePlan.t()} | {:error, atom()}
  def prepare_governance_erasure(tenant_id, target_type, target_id) do
    if Repo.in_transaction?() do
      with :ok <- valid_target(tenant_id, target_type, target_id) do
        protection!(tenant_id, [])
        snapshots = Repo.all(erasure_query(tenant_id, target_type, target_id))
        call_ids = Enum.map(snapshots, & &1.call_id) |> Enum.uniq() |> Enum.sort()

        Repo.all(
          from(c in Call,
            where: c.tenant_id == ^tenant_id and c.id in ^call_ids,
            order_by: c.id,
            lock: "FOR UPDATE"
          )
        )

        ids = Enum.map(snapshots, & &1.id)

        rows =
          Repo.all(
            from(v in Voicemail,
              where: v.tenant_id == ^tenant_id and v.id in ^ids,
              order_by: v.id,
              lock: "FOR UPDATE"
            )
          )

        # Re-read assigned subjects after the call locks. Frozen capture subjects
        # remain protected even when the call's current assignment has changed.
        subjects = rows |> Enum.flat_map(&protected_subjects/1) |> Enum.uniq()

        if rows != [] and protection!(tenant_id, subjects).held do
          {:error, :legal_hold_active}
        else
          timestamp = DateTime.utc_now()
          pending = Enum.count(rows, &erasure_pending?/1)

          Enum.each(rows, fn v ->
            needs_purge = erasure_pending?(v)
            attrs = %{erasure_requested_at: v.erasure_requested_at || timestamp}

            attrs =
              if needs_purge,
                do: Map.merge(attrs, %{status: :deleting, erasure_verified_at: nil}),
                else: attrs

            v |> Voicemail.changeset(attrs) |> Repo.update!()
            capture_changed!(v)
            if needs_purge, do: enqueue!(v.id, timestamp, :delete)
          end)

          {:ok, %VoicemailErasurePlan{pending_voicemail_count: pending}}
        end
      end
    else
      {:error, :transaction_required}
    end
  end

  @spec governance_erasure_pending?(String.t(), :user | :conversation | :message, String.t()) ::
          {:ok, boolean()} | {:error, atom()}
  def governance_erasure_pending?(tenant_id, target_type, target_id) do
    if Repo.in_transaction?() do
      with :ok <- valid_target(tenant_id, target_type, target_id) do
        protection!(tenant_id, [])
        query = erasure_query(tenant_id, target_type, target_id)

        pending =
          Repo.exists?(
            from(v in query,
              where:
                v.status != :deleted or is_nil(v.erasure_verified_at) or
                  is_nil(v.provider_deleted_at) or is_nil(v.deleted_at)
            )
          )

        ids = from(v in query, select: v.id)

        reads =
          Repo.exists?(
            from(r in VoicemailRead,
              where: r.tenant_id == ^tenant_id and r.voicemail_id in subquery(ids)
            )
          )

        {:ok, pending or reads}
      end
    else
      {:error, :transaction_required}
    end
  end

  defp valid_target(tenant_id, type, target_id) do
    if type in [:user, :conversation, :message] and match?({:ok, _}, Ecto.UUID.cast(tenant_id)) and
         match?({:ok, _}, Ecto.UUID.cast(target_id)),
       do: :ok,
       else: {:error, :invalid_governance_target}
  end

  defp erasure_query(tenant_id, :user, target_id) do
    calls =
      from(c in Call, where: c.tenant_id == ^tenant_id and c.user_id == ^target_id, select: c.id)

    boxes =
      from(b in Mailbox,
        where: b.tenant_id == ^tenant_id and b.user_id == ^target_id,
        select: b.id
      )

    from(v in Voicemail,
      where:
        v.tenant_id == ^tenant_id and
          (v.user_id == ^target_id or ^target_id in v.protected_user_ids or
             v.call_id in subquery(calls) or v.mailbox_id in subquery(boxes))
    )
  end

  defp erasure_query(tenant_id, _, _),
    do: from(v in Voicemail, where: v.tenant_id == ^tenant_id and false)

  defp protected_subjects(v),
    do: protected_subjects(v, Repo.get_by!(Call, tenant_id: v.tenant_id, id: v.call_id))

  defp protected_subjects(v, call) do
    box = Repo.get_by!(Mailbox, tenant_id: v.tenant_id, id: v.mailbox_id)

    [v.user_id, call.user_id, box.user_id | v.protected_user_ids || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp erasure_pending?(v),
    do:
      v.status != :deleted or is_nil(v.erasure_verified_at) or is_nil(v.provider_deleted_at) or
        is_nil(v.deleted_at) or
        Repo.exists?(
          from(r in VoicemailRead, where: r.tenant_id == ^v.tenant_id and r.voicemail_id == ^v.id)
        )

  defp delete_reads!(v),
    do:
      Repo.delete_all(
        from(r in VoicemailRead, where: r.tenant_id == ^v.tenant_id and r.voicemail_id == ^v.id)
      )

  defp locked_visible!(id, grant) do
    snapshot = Repo.one(from(v in visible_query(grant), where: v.id == ^id))
    if is_nil(snapshot), do: Repo.rollback(:not_found)
    lock_call!(snapshot.tenant_id, snapshot.call_id)
    Repo.one(from(v in visible_query(grant), where: v.id == ^id, lock: "FOR UPDATE"))
  end

  defp lock_call!(tenant_id, id) do
    case Repo.one(
           from(c in Call, where: c.tenant_id == ^tenant_id and c.id == ^id, lock: "FOR UPDATE")
         ) do
      %Call{} = call -> call
      _ -> Repo.rollback(:not_found)
    end
  end

  defp capture_changed!(v) do
    call = Repo.get_by!(Call, tenant_id: v.tenant_id, id: v.call_id)
    CommsCore.Telephony.CallMonitor.enqueue_capture_monitor!(call, v.recording_deadline)
  end

  defp request(v, operation) do
    call = Repo.get!(Call, v.call_id)

    %VoicemailRequest{
      id: v.id,
      tenant_id: v.tenant_id,
      call_id: v.call_id,
      recording_name: v.recording_name,
      operation: operation,
      provider_room: call.provider_room,
      provider_identity: call.provider_identity,
      external_channel_id: call.pbx_state["external"],
      object: object(v)
    }
  end

  defp object(v),
    do:
      struct(
        VoicemailObject,
        Map.take(v, [
          :tenant_id,
          :object_key,
          :object_version_id,
          :object_etag,
          :checksum_sha256,
          :verified_checksum_sha256,
          :byte_size,
          :content_type
        ])
        |> Map.put(:voicemail_id, v.id)
      )

  defp enqueue!(id, at, trigger) do
    job =
      Oban.Job.new(%{"voicemail_id" => id, "trigger" => Atom.to_string(trigger)},
        worker: RuntimePorts.job_worker_name!(:telephony_voicemail),
        queue: :lifecycle,
        scheduled_at: at,
        max_attempts: 100,
        unique: [
          period: :infinity,
          fields: [:worker, :args],
          keys: [:voicemail_id, :trigger],
          states: [:available, :scheduled, :executing, :retryable]
        ]
      )

    Oban.insert!(job)
  end

  defp protection!(tenant_id, users) do
    case VoicemailProtectionPort.protection(tenant_id, users) do
      {:ok, projection} -> projection
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp locked_access!(subject) do
    case Accounts.lock_access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} -> grant
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp visible_query(grant) do
    shared =
      from(c in Call,
        join: r in Route,
        on: r.id == c.route_id and r.tenant_id == c.tenant_id,
        where:
          c.tenant_id == ^grant.tenant_id and r.enabled == true and r.mode == :shared_line and
            ^grant.user_id in r.member_ids,
        select: c.id
      )

    from(v in Voicemail,
      where:
        v.tenant_id == ^grant.tenant_id and is_nil(v.erasure_requested_at) and
          (v.user_id == ^grant.user_id or v.call_id in subquery(shared))
    )
  end

  defp cursor(nil, _), do: {:ok, nil}
  defp cursor("", _), do: {:ok, nil}

  defp cursor(id, grant) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Voicemail{} = v <- Repo.one(from(v in visible_query(grant), where: v.id == ^uuid)),
         do: {:ok, v},
         else: (_ -> {:error, :invalid_voicemail_cursor})
  end

  defp limit(nil), do: {:ok, 30}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> limit(n)
      _ -> {:error, :invalid_voicemail_limit}
    end
  end

  defp limit(n) when is_integer(n) and n in 1..100, do: {:ok, n}
  defp limit(_), do: {:error, :invalid_voicemail_limit}

  defp audit!(v, actor, action) do
    case Audit.record(%{
           tenant_id: v.tenant_id,
           actor_user_id: actor,
           action: action,
           resource_type: "telephony_voicemail",
           resource_id: v.id,
           metadata: %{call_id: v.call_id}
         }) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_failed)
    end
  end

  defp access(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} -> {:ok, grant}
      _ -> {:error, :forbidden}
    end
  end

  defp view(v, read_at),
    do:
      Map.take(v, [
        :id,
        :call_id,
        :status,
        :duration_seconds,
        :retention_expires_at,
        :available_at,
        :inserted_at
      ])
      |> Map.put(:read_at, read_at)

  defp visible_box(nil), do: nil

  defp visible_box(box),
    do: Map.take(box, [:id, :user_id, :enabled, :retention_days, :notice_media, :version])

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
