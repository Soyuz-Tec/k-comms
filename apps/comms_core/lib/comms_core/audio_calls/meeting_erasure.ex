defmodule CommsCore.AudioCalls.MeetingErasure do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Audit, Repo, RuntimePorts}

  alias CommsCore.AudioCalls.{
    ArtifactProtectionPort,
    Lifecycle,
    Meeting,
    MeetingErasurePlan,
    MeetingOccurrence
  }

  @neutral_title "[Deleted meeting]"
  @neutral_start ~N[1970-01-01 00:00:00]
  @neutral_instant ~U[1970-01-01 00:00:00Z]
  @neutral_end ~U[1970-01-01 00:05:00Z]
  @neutral_recurrence %{"frequency" => "none", "interval" => 1, "count" => 1}
  @neutral_policy %{"allow_guests" => false, "join_before_host" => false}

  def prepare(tenant_id, type, target_id) when type in [:user, :conversation, :message] do
    with true <- Repo.in_transaction?(),
         {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, target_id} <- Ecto.UUID.cast(target_id) do
      # A nested owner boundary returns its typed error to Governance's mapper.
      # Any owner rollback still aborts the enclosing claim transaction, so
      # no scrubbing or preparation can commit after a failed hold assessment.
      Repo.transaction(fn -> prepare!(tenant_id, type, target_id) end)
    else
      false -> {:error, :transaction_required}
      _ -> {:error, :invalid_governance_target}
    end
  end

  def prepare(_, _, _), do: {:error, :invalid_governance_target}

  defp prepare!(tenant_id, type, target_id) do
    if type == :user, do: repair_tenant_authorship!(tenant_id)

    meetings =
      Repo.all(scope(tenant_id, type, target_id))
      |> Enum.map(fn meeting ->
        protection!(meeting.tenant_id, meeting.conversation_id, authors(meeting))
        repair_authorship!(meeting)
      end)

    # Assess every held scope before changing any personal content. The port
    # retains Governance's existing tenant lock throughout this transaction.
    Enum.each(meetings, fn meeting ->
      if protection!(meeting.tenant_id, meeting.conversation_id, authors(meeting)).held,
        do: Repo.rollback(:meeting_legal_hold)
    end)

    scrubbed_count =
      Enum.reduce(meetings, 0, fn snapshot, count ->
        meeting =
          Repo.one!(
            from(m in Meeting,
              where: m.id == ^snapshot.id and m.tenant_id == ^tenant_id,
              lock: "FOR UPDATE"
            )
          )

        if verified?(meeting) do
          count
        else
          if protection!(meeting.tenant_id, meeting.conversation_id, authors(meeting)).held,
            do: Repo.rollback(:meeting_legal_hold)

          scrub!(meeting, type, target_id)
          count + 1
        end
      end)

    %MeetingErasurePlan{
      pending_meeting_count: pending_count(tenant_id, type, target_id),
      scrubbed_meeting_count: scrubbed_count
    }
  end

  def pending?(tenant_id, type, target_id) when type in [:user, :conversation, :message] do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, target_id} <- Ecto.UUID.cast(target_id) do
      {:ok, pending_count(tenant_id, type, target_id) > 0}
    else
      _ -> {:error, :invalid_governance_target}
    end
  end

  def pending?(_, _, _), do: {:error, :invalid_governance_target}

  def guard!(tenant_id, conversation_id, user_ids) do
    if protection!(tenant_id, conversation_id, user_ids).capture_blocked,
      do: Repo.rollback(:meeting_erasure_pending)

    :ok
  end

  def guard_meeting!(meeting, extra_authors \\ []) do
    protection!(meeting.tenant_id, meeting.conversation_id, authors(meeting) ++ extra_authors)
    current = Repo.get_by!(Meeting, id: meeting.id, tenant_id: meeting.tenant_id)
    if current.erasure_requested_at || current.erased_at, do: Repo.rollback(:not_found)
    current = repair_authorship!(current)
    guard!(current.tenant_id, current.conversation_id, authors(current) ++ extra_authors)
    current
  end

  def readable(meeting) do
    protection!(meeting.tenant_id, meeting.conversation_id, authors(meeting))
    current = Repo.get_by!(Meeting, id: meeting.id, tenant_id: meeting.tenant_id)

    if current.erasure_requested_at || current.erased_at do
      :hidden
    else
      current = repair_authorship!(current)

      if protection!(current.tenant_id, current.conversation_id, authors(current)).capture_blocked,
        do: :hidden,
        else: {:ok, current}
    end
  end

  def unsanitized_count, do: Repo.aggregate(unverified_query(), :count, :id)

  defp repair_tenant_authorship!(tenant_id) do
    Repo.all(
      from(m in Meeting,
        where:
          m.tenant_id == ^tenant_id and not m.author_lineage_complete and is_nil(m.erased_at),
        order_by: [asc: m.id]
      )
    )
    |> Enum.each(fn meeting ->
      protection!(tenant_id, meeting.conversation_id, authors(meeting))
      repair_authorship!(meeting)
    end)
  end

  defp repair_authorship!(%Meeting{author_lineage_complete: true} = meeting), do: meeting

  defp repair_authorship!(%Meeting{} = meeting) do
    events = audit_history(meeting, nil, [])
    # Historical title edits were already atomically audited. Missing history
    # cannot establish the authors to whom a user hold must apply; fail closed.
    authorship_events =
      Enum.filter(
        events,
        &(&1.action in ["meeting.scheduled", "meeting.updated", "meeting.cancelled"])
      )

    versions =
      authorship_events
      |> Enum.map(&Map.get(&1.metadata, "version", Map.get(&1.metadata, :version)))
      |> Enum.uniq()
      |> Enum.sort()

    unless versions == Enum.to_list(1..meeting.version) and
             Enum.all?(authorship_events, &is_binary(&1.actor_user_id)),
           do: Repo.rollback(:meeting_authorship_unavailable)

    ids =
      [meeting.host_user_id | Enum.map(events, & &1.actor_user_id)]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    meeting
    |> Ecto.Changeset.change(author_user_ids: ids, author_lineage_complete: true)
    |> Repo.update!()
  end

  defp audit_history(meeting, before, acc) do
    filters = %{
      tenant_id: meeting.tenant_id,
      resource_type: "meeting",
      resource_id: meeting.id,
      limit: 100,
      before: before
    }

    events = Audit.list(filters)

    if length(events) == 100 do
      last = List.last(events)
      audit_history(meeting, {last.inserted_at, last.id}, events ++ acc)
    else
      events ++ acc
    end
  end

  defp scrub!(%Meeting{} = meeting, type, target_id) do
    occurrences =
      Repo.all(
        from(o in MeetingOccurrence,
          where: o.tenant_id == ^meeting.tenant_id and o.meeting_id == ^meeting.id
        )
      )

    occurrences
    |> Enum.map(& &1.call_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn call_id ->
      case Lifecycle.revoke_for_call(meeting.tenant_id, call_id, "meeting_governance_erasure") do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(o in MeetingOccurrence,
        where: o.tenant_id == ^meeting.tenant_id and o.meeting_id == ^meeting.id
      ),
      set: [
        status: :cancelled,
        starts_at: @neutral_instant,
        ends_at: @neutral_end,
        reminder_at: @neutral_instant,
        reminder_sent_at: nil,
        updated_at: now
      ]
    )

    occurrence_ids = Enum.map(occurrences, & &1.id)
    worker = RuntimePorts.job_worker_name!(:meeting_reminder)

    {:ok, _} =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where:
            j.worker == ^worker and
              j.state in ["available", "scheduled", "retryable", "executing"] and
              fragment("?->>'occurrence_id'", j.args) in ^occurrence_ids
        )
      )

    # Keep opaque scope correlation for verification, never a displayed host or title.
    fingerprint =
      if type == :user,
        do: fingerprint(meeting.tenant_id, target_id),
        else: meeting.erasure_user_fingerprint

    meeting
    |> Ecto.Changeset.change(%{
      title: @neutral_title,
      host_user_id: nil,
      author_user_ids: [],
      author_lineage_complete: true,
      timezone: "Etc/UTC",
      local_start: @neutral_start,
      duration_minutes: 5,
      recurrence: @neutral_recurrence,
      reminder_minutes: 0,
      host_policy: @neutral_policy,
      status: :cancelled,
      version: meeting.version + 1,
      erasure_requested_at: meeting.erasure_requested_at || now,
      erased_at: now,
      erasure_user_fingerprint: fingerprint
    })
    |> Repo.update!()
  end

  defp pending_count(tenant_id, type, target_id) do
    meetings = Repo.all(scope(tenant_id, type, target_id))
    Enum.count(meetings, &(not verified?(&1)))
  end

  defp scope(tenant_id, type, target_id) do
    query = from(m in Meeting, where: m.tenant_id == ^tenant_id, order_by: [asc: m.id])

    case type do
      :conversation ->
        where(query, [m], m.conversation_id == ^target_id)

      :user ->
        marker = fingerprint(tenant_id, target_id)

        where(
          query,
          [m],
          m.host_user_id == ^target_id or ^target_id in m.author_user_ids or
            m.erasure_user_fingerprint == ^marker or
            (not m.author_lineage_complete and is_nil(m.erased_at))
        )

      :message ->
        where(query, false)
    end
  end

  defp verified?(meeting) do
    not Repo.exists?(
      where(unverified_query(), [m], m.id == ^meeting.id and m.tenant_id == ^meeting.tenant_id)
    )
  end

  defp unverified_query do
    from(m in Meeting,
      where:
        is_nil(m.erased_at) or is_nil(m.erasure_requested_at) or m.status != :cancelled or
          not is_nil(m.host_user_id) or m.author_user_ids != ^[] or not m.author_lineage_complete or
          m.title != ^@neutral_title or m.timezone != "Etc/UTC" or
          m.local_start != ^@neutral_start or
          m.duration_minutes != 5 or m.recurrence != ^@neutral_recurrence or
          m.reminder_minutes != 0 or m.host_policy != ^@neutral_policy or
          m.id in subquery(
            from(o in MeetingOccurrence,
              where:
                o.status != :cancelled or o.starts_at != ^@neutral_instant or
                  o.ends_at != ^@neutral_end or
                  o.reminder_at != ^@neutral_instant or not is_nil(o.reminder_sent_at),
              select: o.meeting_id
            )
          )
    )
  end

  defp authors(meeting),
    do:
      [meeting.host_user_id | meeting.author_user_ids || []]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

  defp protection!(tenant_id, conversation_id, user_ids) do
    case ArtifactProtectionPort.protection(tenant_id, conversation_id, Enum.uniq(user_ids)) do
      {:ok, protection} -> protection
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fingerprint(tenant_id, user_id),
    do: :crypto.hash(:sha256, "meeting-erasure:" <> tenant_id <> ":" <> user_id)
end
