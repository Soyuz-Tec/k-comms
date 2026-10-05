defmodule CommsCore.AudioCalls.Meetings do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Audit, Conversations, Outbox, Repo, RuntimePorts}
  alias CommsCore.AudioCalls.CalendarSync.{Budget, SourceContributionQuery, SourceContributions}

  alias CommsCore.AudioCalls.{
    AudioCall,
    AuthorizationPolicy,
    Lifecycle,
    Meeting,
    MeetingCalendar,
    MeetingCallPolicy,
    MeetingErasure,
    MeetingOccurrence,
    MeetingSchedule,
    MeetingView
  }

  @doc false
  @spec rollback_hazard_count() :: non_neg_integer()
  def rollback_hazard_count() do
    # Retained meeting metadata requires the erasure fence even when cancelled.
    # Old targets are safe only after verified owner scrubbing and room teardown.
    require_rollback_table!("meetings")
    require_rollback_table!("meeting_occurrences")
    require_rollback_table!("audio_calls")
    meetings = MeetingErasure.unsanitized_count()

    occurrences =
      Repo.aggregate(from(o in MeetingOccurrence, where: o.status == :scheduled), :count, :id)

    active_calls =
      Repo.aggregate(
        from(o in MeetingOccurrence,
          join: c in AudioCall,
          on: c.tenant_id == o.tenant_id and c.id == o.call_id,
          where: c.status in [:active, :ending]
        ),
        :count,
        :id
      )

    rollback_count!(meetings) + rollback_count!(occurrences) + rollback_count!(active_calls)
  end

  defp require_rollback_table!(table) do
    case Repo.query!("SELECT to_regclass($1) IS NOT NULL", ["public." <> table]).rows do
      [[true]] -> :ok
      _ -> raise "Calls meeting rollback inventory unavailable"
    end
  end

  defp rollback_count!(count) when is_integer(count) and count >= 0, do: count
  defp rollback_count!(_), do: raise("Invalid Calls meeting rollback hazard count")

  def create(conversation_id, attrs, subject) do
    with {:ok, grant} <- human_grant(subject),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         {:ok, validated, occurrences} <- MeetingSchedule.validate(attrs) do
      transaction(fn ->
        MeetingErasure.guard!(grant.tenant_id, conversation_id, [grant.user_id])
        access = access!(subject, conversation_id, :update)

        meeting_attrs =
          Map.merge(validated, %{
            tenant_id: grant.tenant_id,
            conversation_id: conversation_id,
            host_user_id: grant.user_id,
            author_user_ids: [grant.user_id],
            author_lineage_complete: true
          })

        changeset = Meeting.changeset(%Meeting{}, meeting_attrs)
        meeting = insert!(changeset)
        materialize!(meeting, occurrences)
        record!(meeting, subject, "scheduled")
        view(meeting, access.user_id, access.membership_role)
      end)
    else
      :error -> {:error, :invalid_conversation_id}
      error -> error
    end
  end

  def update(id, attrs, subject) do
    with {:ok, _grant} <- human_grant(subject),
         {:ok, initial} <- accessible(id, subject),
         {:ok, expected} <- expected_version(attrs),
         {:ok, validated, occurrences} <- MeetingSchedule.validate(attrs) do
      transaction(fn ->
        contribution =
          SourceContributions.prepare!(%SourceContributionQuery{
            subject: subject,
            meeting_id: initial.id,
            deadline_ms: Budget.deadline()
          })

        initial = MeetingErasure.guard_meeting!(initial, [value(subject, :user_id)])
        access = access!(subject, initial.conversation_id, :update)
        meeting = meeting!(id, initial.tenant_id, "FOR UPDATE")
        manage!(meeting, access)
        version!(meeting, expected)
        unless meeting.status == :scheduled, do: Repo.rollback(:meeting_cancelled)
        current = occurrence_query(meeting) |> Repo.all()
        if Enum.any?(current, &(&1.call_id != nil)), do: Repo.rollback(:meeting_already_started)
        Repo.update_all(occurrence_query(meeting), set: [status: :cancelled, updated_at: now()])

        meeting =
          meeting
          |> Meeting.changeset(
            Map.merge(validated, %{
              version: meeting.version + 1,
              author_user_ids: Enum.uniq([access.user_id | meeting.author_user_ids])
            })
          )
          |> update!()

        materialize!(meeting, occurrences)
        SourceContributions.record!(contribution, meeting)
        record!(meeting, subject, "updated")
        view(meeting, access.user_id, access.membership_role)
      end)
    end
  end

  def cancel(id, attrs, subject) do
    with {:ok, _grant} <- human_grant(subject),
         {:ok, initial} <- accessible(id, subject),
         {:ok, expected} <- expected_version(attrs) do
      transaction(fn ->
        contribution =
          SourceContributions.prepare!(%SourceContributionQuery{
            subject: subject,
            meeting_id: initial.id,
            deadline_ms: Budget.deadline()
          })

        initial = MeetingErasure.guard_meeting!(initial, [value(subject, :user_id)])
        access = access!(subject, initial.conversation_id, :update)
        meeting = meeting!(id, initial.tenant_id, "FOR UPDATE")
        manage!(meeting, access)
        version!(meeting, expected)

        if meeting.status == :scheduled do
          current = Repo.all(occurrence_query(meeting))

          Enum.each(current, fn occurrence ->
            if occurrence.call_id do
              case Lifecycle.revoke_for_call(
                     meeting.tenant_id,
                     occurrence.call_id,
                     "meeting_cancelled"
                   ) do
                {:ok, _} -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end
            end
          end)

          Repo.update_all(occurrence_query(meeting),
            set: [status: :cancelled, meeting_version: meeting.version + 1, updated_at: now()]
          )

          meeting =
            meeting
            |> Meeting.changeset(%{status: :cancelled, version: meeting.version + 1})
            |> update!()

          SourceContributions.record!(contribution, meeting)
          record!(meeting, subject, "cancelled")
          view(meeting, access.user_id, access.membership_role)
        else
          view(meeting, access.user_id, access.membership_role)
        end
      end)
    end
  end

  def get(id, subject) do
    with {:ok, meeting} <- accessible(id, subject),
         {:ok, grant} <- human_grant(subject),
         {:ok, membership} <-
           Conversations.call_membership(grant.tenant_id, meeting.conversation_id, grant.user_id) do
      transaction(fn ->
        case MeetingErasure.readable(meeting) do
          {:ok, current} -> view(current, grant.user_id, membership.role)
          :hidden -> Repo.rollback(:not_found)
        end
      end)
    end
  end

  def list(subject, params) do
    with {:ok, grant} <- human_grant(subject),
         {:ok, from_at, to_at} <- bounds(params) do
      transaction(fn ->
        authorization = Conversations.active_membership_authorization_query(grant)

        items =
          Repo.all(
            from(meeting in Meeting,
              join: occurrence in MeetingOccurrence,
              on:
                occurrence.meeting_id == meeting.id and
                  occurrence.meeting_version == meeting.version,
              join: access in subquery(authorization),
              on: access.conversation_id == meeting.conversation_id,
              where:
                meeting.tenant_id == ^grant.tenant_id and is_nil(meeting.erasure_requested_at) and
                  is_nil(meeting.erased_at) and occurrence.starts_at >= ^from_at and
                  occurrence.starts_at < ^to_at,
              order_by: [asc: occurrence.starts_at, asc: meeting.id],
              select: %{meeting: meeting, role: access.membership_role},
              limit: 501
            )
          )

        distinct = Enum.uniq_by(items, & &1.meeting.id)

        %{
          meetings:
            distinct |> Enum.take(500) |> Enum.flat_map(&visible_views(&1, grant.user_id)),
          truncated: length(items) > 500
        }
      end)
    end
  end

  def search(subject, params) do
    with {:ok, grant} <- human_grant(subject),
         query when is_binary(query) <- value(params, :q),
         query = String.trim(query),
         true <- String.length(query) in 1..160,
         {:ok, from_at} <- instant(value(params, :after), DateTime.add(now(), -366 * 86_400)),
         {:ok, to_at} <- instant(value(params, :before), DateTime.add(now(), 366 * 86_400)),
         seconds = DateTime.diff(to_at, from_at),
         true <- seconds > 0 and seconds <= 732 * 86_400,
         {:ok, conversation_id} <- optional_conversation(value(params, :conversation_id)) do
      transaction(fn ->
        limit = search_limit(value(params, :limit))
        authorization = Conversations.active_membership_authorization_query(grant)
        # strpos treats %, _ and backslashes as literal characters, never wildcards.
        base =
          from(meeting in Meeting,
            join: occurrence in MeetingOccurrence,
            on:
              occurrence.meeting_id == meeting.id and
                occurrence.meeting_version == meeting.version,
            join: access in subquery(authorization),
            on: access.conversation_id == meeting.conversation_id,
            where:
              meeting.tenant_id == ^grant.tenant_id and is_nil(meeting.erasure_requested_at) and
                is_nil(meeting.erased_at) and occurrence.starts_at >= ^from_at and
                occurrence.starts_at < ^to_at and
                fragment("strpos(lower(?), lower(?)) > 0", meeting.title, ^query),
            distinct: true,
            order_by: [desc: meeting.updated_at, desc: meeting.id],
            select: %{meeting: meeting, role: access.membership_role},
            limit: ^(limit + 1)
          )

        base =
          if conversation_id,
            do: where(base, [meeting], meeting.conversation_id == ^conversation_id),
            else: base

        results = Repo.all(base)

        %{
          meetings:
            results |> Enum.take(limit) |> Enum.flat_map(&visible_views(&1, grant.user_id)),
          truncated: length(results) > limit
        }
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_search_query}
    end
  end

  def calendar(id, subject) do
    transaction(fn ->
      with {:ok, meeting} <- get(id, subject),
           {:ok, grant} <- human_grant(subject) do
        current_sequences = Enum.map(meeting.occurrences, & &1.sequence)
        # Stable occurrence UIDs require cancellation tombstones when an edited
        # finite recurrence shrinks. Otherwise previously imported dates linger.
        removed =
          Repo.all(
            from(item in MeetingOccurrence,
              where:
                item.tenant_id == ^grant.tenant_id and item.meeting_id == ^meeting.id and
                  item.sequence not in ^current_sequences and item.status == :cancelled,
              distinct: item.sequence,
              order_by: [asc: item.sequence, desc: item.meeting_version]
            )
          )
          |> Enum.map(&Map.take(&1, [:id, :sequence, :starts_at, :ends_at, :status, :call_id]))

        MeetingCalendar.render(%{meeting | occurrences: meeting.occurrences ++ removed})
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defdelegate meeting_for_call(tenant_id, call_id), to: MeetingCallPolicy

  def start(id, occurrence_id, subject, media_kind, cleanup, issuer) do
    with {:ok, grant} <- human_grant(subject),
         {:ok, initial} <- accessible(id, subject),
         {:ok, occurrence_id} <- Ecto.UUID.cast(occurrence_id),
         true <- media_kind in [:audio, :video] do
      transaction(fn ->
        initial = MeetingErasure.guard_meeting!(initial, [value(subject, :user_id)])
        access = access!(subject, initial.conversation_id, :update)
        meeting = meeting!(id, grant.tenant_id, "FOR UPDATE")

        occurrence =
          Repo.one(
            from(item in occurrence_query(meeting),
              where: item.id == ^occurrence_id,
              lock: "FOR UPDATE"
            )
          )

        unless occurrence, do: Repo.rollback(:not_found)

        unless meeting.status == :scheduled and occurrence.status == :scheduled,
          do: Repo.rollback(:meeting_cancelled)

        unless DateTime.diff(occurrence.starts_at, now()) <= 900 and
                 DateTime.compare(now(), occurrence.ends_at) == :lt,
               do: Repo.rollback(:meeting_not_joinable)

        if is_nil(occurrence.call_id) and access.user_id != meeting.host_user_id and
             meeting.host_policy["join_before_host"] != true,
           do: Repo.rollback(:meeting_host_required)

        active_call =
          Repo.one(
            from(call in AudioCall,
              where:
                call.tenant_id == ^meeting.tenant_id and
                  call.conversation_id == ^meeting.conversation_id and
                  call.status != :ended and call.expires_at > ^now(),
              lock: "FOR UPDATE"
            )
          )

        if occurrence.call_id && (is_nil(active_call) or active_call.id != occurrence.call_id),
          do: Repo.rollback(:meeting_already_started)

        if active_call && active_call.id != occurrence.call_id,
          do: Repo.rollback(:active_call_conflict)

        case Lifecycle.start_with_join_authorized(
               meeting.conversation_id,
               subject,
               media_kind,
               cleanup,
               issuer
             ) do
          {:ok, call, status, credential} ->
            if status == :existing and occurrence.call_id != call.id,
              do: Repo.rollback(:active_call_conflict)

            if occurrence.call_id && occurrence.call_id != call.id,
              do: Repo.rollback(:meeting_already_started)

            occurrence |> MeetingOccurrence.changeset(%{call_id: call.id}) |> update!()
            %{call: call, status: status, credential: credential}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
      false -> {:error, :invalid_media_kind}
      error -> error
    end
  end

  defdelegate authorize_call_access!(call, subject), to: MeetingCallPolicy

  def deliver_reminder(occurrence_id, version, caller) do
    if RuntimePorts.authorized_job_worker?(:meeting_reminder, caller) do
      transaction(fn ->
        initial = Repo.get(MeetingOccurrence, occurrence_id)

        if initial do
          snapshot = Repo.get_by!(Meeting, id: initial.meeting_id, tenant_id: initial.tenant_id)

          if snapshot.erasure_requested_at || snapshot.erased_at do
            :ignored
          else
            visibility = MeetingErasure.readable(snapshot)
            meeting = meeting!(initial.meeting_id, initial.tenant_id, "FOR SHARE")

            occurrence =
              Repo.one(
                from(item in MeetingOccurrence,
                  where: item.id == ^occurrence_id,
                  lock: "FOR UPDATE"
                )
              )

            cond do
              visibility == :hidden or meeting.status != :scheduled or
                occurrence.status != :scheduled or
                meeting.version != version or occurrence.meeting_version != version ->
                :ignored

              occurrence.reminder_sent_at != nil ->
                :already_delivered

              DateTime.compare(now(), occurrence.ends_at) != :lt ->
                :ignored

              DateTime.compare(now(), occurrence.reminder_at) == :lt ->
                Repo.rollback(:meeting_reminder_not_due)

              true ->
                event!(meeting, "reminder", %{
                  occurrence_id: occurrence.id,
                  starts_at: DateTime.to_iso8601(occurrence.starts_at)
                })

                occurrence |> MeetingOccurrence.changeset(%{reminder_sent_at: now()}) |> update!()
                :delivered
            end
          end
        else
          :ignored
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  def prepare_governance_erasure(tenant_id, type, target_id),
    do: MeetingErasure.prepare(tenant_id, type, target_id)

  def governance_erasure_pending?(tenant_id, type, target_id),
    do: MeetingErasure.pending?(tenant_id, type, target_id)

  defp visible_views(%{meeting: meeting, role: role}, user_id) do
    case MeetingErasure.readable(meeting) do
      {:ok, current} -> [view(current, user_id, role)]
      :hidden -> []
    end
  end

  defp accessible(id, subject) do
    with {:ok, grant} <- human_grant(subject),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Meeting{} = meeting <-
           Repo.one(
             from(meeting in Meeting,
               where:
                 meeting.id == ^id and meeting.tenant_id == ^grant.tenant_id and
                   is_nil(meeting.erasure_requested_at) and is_nil(meeting.erased_at)
             )
           ),
         :ok <- AuthorizationPolicy.authorize(:read_call, subject, %{id: meeting.conversation_id}) do
      {:ok, meeting}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp human_grant(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %{account_type: :human, access_scope: :workspace} = grant} -> {:ok, grant}
      _ -> {:error, :forbidden}
    end
  end

  defp access!(subject, conversation_id, mode) do
    case AuthorizationPolicy.lock_access(subject, conversation_id, mode) do
      {:ok, access} ->
        unless access.allow_audio_calls or access.allow_video_calls,
          do: Repo.rollback(:audio_calls_disabled)

        access

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp meeting!(id, tenant_id, lock) do
    query = from(meeting in Meeting, where: meeting.id == ^id and meeting.tenant_id == ^tenant_id)

    query =
      case lock do
        "FOR UPDATE" -> lock(query, "FOR UPDATE")
        "FOR SHARE" -> lock(query, "FOR SHARE")
      end

    Repo.one(query) || Repo.rollback(:not_found)
  end

  defp manage!(meeting, access) do
    unless meeting.host_user_id == access.user_id or
             access.membership_role in [:owner, :moderator],
           do: Repo.rollback(:forbidden)
  end

  defp version!(meeting, expected),
    do: if(meeting.version != expected, do: Repo.rollback(:stale_version))

  defp expected_version(attrs) do
    case value(attrs, :expected_version) do
      version when is_integer(version) and version > 0 -> {:ok, version}
      _ -> {:error, :version_required}
    end
  end

  defp materialize!(meeting, occurrences) do
    occurrences
    |> Enum.with_index(1)
    |> Enum.each(fn {attrs, sequence} ->
      occurrence_attrs =
        Map.merge(attrs, %{
          tenant_id: meeting.tenant_id,
          meeting_id: meeting.id,
          conversation_id: meeting.conversation_id,
          meeting_version: meeting.version,
          sequence: sequence
        })

      changeset = MeetingOccurrence.changeset(%MeetingOccurrence{}, occurrence_attrs)
      occurrence = insert!(changeset)

      scheduled_at =
        if DateTime.compare(occurrence.reminder_at, now()) == :lt,
          do: now(),
          else: occurrence.reminder_at

      %{
        "occurrence_id" => occurrence.id,
        "version" => meeting.version,
        "tenant_id" => meeting.tenant_id
      }
      |> Oban.Job.new(
        worker: RuntimePorts.job_worker_name!(:meeting_reminder),
        queue: :media,
        scheduled_at: scheduled_at,
        max_attempts: 10
      )
      |> Repo.insert!()
    end)
  end

  defp view(meeting, user_id, role) do
    fields =
      Map.take(meeting, [
        :id,
        :conversation_id,
        :host_user_id,
        :title,
        :timezone,
        :local_start,
        :duration_minutes,
        :reminder_minutes,
        :status,
        :version
      ])

    struct!(
      MeetingView,
      Map.merge(fields, %{
        recurrence: %{
          frequency: meeting.recurrence["frequency"],
          interval: meeting.recurrence["interval"],
          count: meeting.recurrence["count"]
        },
        host_policy: %{
          allow_guests: meeting.host_policy["allow_guests"],
          join_before_host: meeting.host_policy["join_before_host"]
        },
        can_manage: meeting.host_user_id == user_id or role in [:owner, :moderator],
        occurrences:
          Repo.all(from(item in occurrence_query(meeting), order_by: [asc: item.sequence]))
          |> Enum.map(&Map.take(&1, [:id, :sequence, :starts_at, :ends_at, :status, :call_id]))
      })
    )
  end

  defp occurrence_query(meeting),
    do:
      from(item in MeetingOccurrence,
        where:
          item.tenant_id == ^meeting.tenant_id and item.meeting_id == ^meeting.id and
            item.meeting_version == ^meeting.version
      )

  defp record!(meeting, subject, action) do
    case Audit.record(%{
           tenant_id: meeting.tenant_id,
           actor_user_id: value(subject, :user_id),
           request_id: value(subject, :request_id),
           action: "meeting.#{action}",
           resource_type: "meeting",
           resource_id: meeting.id,
           metadata: %{version: meeting.version, conversation_id: meeting.conversation_id}
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    event!(meeting, action, %{})
  end

  defp event!(meeting, action, extra) do
    Outbox.insert_and_enqueue!(%{
      tenant_id: meeting.tenant_id,
      event_type: "meeting.#{action}.v1",
      aggregate_type: "meeting",
      aggregate_id: meeting.id,
      available_at: now(),
      payload:
        Map.merge(
          %{
            meeting_id: meeting.id,
            conversation_id: meeting.conversation_id,
            host_user_id: meeting.host_user_id,
            version: meeting.version
          },
          extra
        )
    })
  end

  defp bounds(params) do
    with {:ok, first} <- instant(value(params, :from), now()),
         {:ok, last} <- instant(value(params, :to), DateTime.add(first, 31 * 86_400)),
         seconds = DateTime.diff(last, first),
         true <- seconds > 0 and seconds <= 93 * 86_400 do
      {:ok, first, last}
    else
      _ -> {:error, :invalid_meeting_range}
    end
  end

  defp instant(nil, default), do: {:ok, default}

  defp instant(input, _) when is_binary(input) do
    case DateTime.from_iso8601(input) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> {:error, :invalid_meeting_range}
    end
  end

  defp instant(_, _), do: {:error, :invalid_meeting_range}
  defp optional_conversation(nil), do: {:ok, nil}

  defp optional_conversation(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      _ -> {:error, :invalid_conversation_id}
    end
  end

  defp search_limit(value) when is_integer(value), do: value |> max(1) |> min(50)

  defp search_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> search_limit(number)
      _ -> 20
    end
  end

  defp search_limit(_), do: 20
  defp transaction(fun), do: Repo.transaction(fun)
  defp insert!(changeset), do: persist!(Repo.insert(changeset))
  defp update!(changeset), do: persist!(Repo.update(changeset))
  defp persist!({:ok, record}), do: record

  defp persist!({:error, changeset}) do
    case CommsCore.ValidationError.from(changeset) do
      {:ok, error} -> Repo.rollback(error)
      :error -> Repo.rollback(:invalid_meeting)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
