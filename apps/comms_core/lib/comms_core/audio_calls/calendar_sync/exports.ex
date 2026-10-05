defmodule CommsCore.AudioCalls.CalendarSync.Exports do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Conversations, Repo}
  alias CommsCore.AudioCalls.{Meeting, MeetingOccurrence}

  alias CommsCore.AudioCalls.CalendarSync.{
    Budget,
    Commands,
    Connection,
    EventMapping,
    Export,
    ExportView,
    Guards
  }

  def list(subject, attrs) do
    Budget.transaction(fn deadline ->
      tenant = value(subject, :tenant_id)
      user = value(subject, :user_id)
      Guards.protection!(tenant, nil, [user], deadline, :read)
      Guards.actor!(subject, deadline)

      query =
        from(e in Export,
          where: e.tenant_id == ^tenant and e.user_id == ^user,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: 101
        )

      query =
        case value(attrs, :meeting_id) do
          nil ->
            query

          id ->
            id =
              case Ecto.UUID.cast(id) do
                {:ok, valid} -> valid
                _ -> Repo.rollback(:invalid_meeting_id)
              end

            where(query, [e], e.meeting_id == ^id)
        end

      items = Repo.all(query)

      views =
        items
        |> Enum.take(100)
        |> Enum.flat_map(fn export ->
          case Conversations.call_membership(tenant, export.conversation_id, user) do
            {:ok, _} -> [view(export)]
            _ -> []
          end
        end)

      Guards.revalidate!(subject, deadline)
      %{exports: views, truncated: length(items) > 100}
    end)
  end

  def create(attrs, subject) do
    with {:ok, connection_id} <- Ecto.UUID.cast(value(attrs, :connection_id)),
         {:ok, meeting_id} <- Ecto.UUID.cast(value(attrs, :meeting_id)),
         {:ok, meeting_version} <- version(value(attrs, :meeting_version)) do
      Budget.transaction(fn deadline ->
        tenant = value(subject, :tenant_id)
        user = value(subject, :user_id)

        snapshot =
          Repo.get_by(Meeting, id: meeting_id, tenant_id: tenant) || Repo.rollback(:not_found)

        Guards.protection!(
          tenant,
          snapshot.conversation_id,
          authors!(snapshot),
          deadline,
          :export
        )

        Guards.actor!(subject, deadline, true)
        policy = Guards.policy!(tenant, deadline, :export)

        connection =
          Repo.one(
            from(c in Connection,
              where:
                c.id == ^connection_id and
                  c.tenant_id == ^tenant and c.user_id == ^user,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        unless policy.export_allowed? and connection.status == :ready and
                 is_nil(connection.fenced_at) and
                 connection.export_policy_version == policy.version,
               do: Repo.rollback(:calendar_export_disabled)

        meeting =
          Repo.one(
            from(m in Meeting,
              where: m.id == ^meeting_id and m.tenant_id == ^tenant,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        current_source!(meeting, user, meeting_version)

        case Conversations.call_membership(tenant, meeting.conversation_id, user) do
          {:ok, _} -> :ok
          _ -> Repo.rollback(:forbidden)
        end

        existing =
          Repo.one(
            from(e in Export,
              where:
                e.connection_id == ^connection.id and
                  e.meeting_id == ^meeting.id and
                  e.consent_generation == ^connection.consent_generation,
              lock: "FOR UPDATE"
            )
          )

        export =
          if existing do
            if existing.tombstoned_at, do: Repo.rollback(:calendar_export_terminal)
            existing
          else
            Repo.insert!(%Export{
              id: Ecto.UUID.generate(),
              tenant_id: tenant,
              connection_id: connection.id,
              user_id: user,
              meeting_id: meeting.id,
              conversation_id: meeting.conversation_id,
              consent_generation: connection.consent_generation,
              desired_meeting_version: meeting.version,
              author_user_ids: authors!(meeting),
              author_lineage_complete: true
            })
          end

        synchronize!(connection, export, meeting, true)
        Guards.revalidate!(subject, deadline, true)
        view(Repo.get!(Export, export.id))
      end)
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  def resolve(id, attrs, subject) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, expected} <- version(value(attrs, :version)),
         decision when decision in ["reexport_current", "stop_syncing"] <- value(attrs, :decision) do
      Budget.transaction(fn deadline ->
        tenant = value(subject, :tenant_id)
        user = value(subject, :user_id)

        initial =
          Repo.get_by(Export, id: id, tenant_id: tenant, user_id: user) ||
            Repo.rollback(:not_found)

        Guards.protection!(
          tenant,
          initial.conversation_id,
          initial.author_user_ids,
          deadline,
          if(decision == "stop_syncing", do: :cleanup, else: :export)
        )

        Guards.actor!(subject, deadline, true)
        policy = Guards.policy!(tenant, deadline, :export)

        connection =
          Repo.one(
            from(c in Connection,
              where:
                c.id == ^initial.connection_id and
                  c.tenant_id == ^tenant and c.user_id == ^user,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        meeting =
          Repo.one(
            from(m in Meeting,
              where: m.id == ^initial.meeting_id and m.tenant_id == ^tenant,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        export = Repo.one(from(e in Export, where: e.id == ^id, lock: "FOR UPDATE"))
        if export.version != expected, do: Repo.rollback(:stale_version)

        if decision == "stop_syncing" do
          stop!(connection, export, "consent_withdrawn")
        else
          source_version = version(value(attrs, :meeting_version)) |> Guards.unwrap!()
          current_source!(meeting, user, source_version)

          unless policy.export_allowed? and connection.status == :ready and
                   is_nil(connection.fenced_at) and
                   is_nil(export.tombstoned_at),
                 do: Repo.rollback(:calendar_export_disabled)

          export =
            Repo.update!(
              Ecto.Changeset.change(export,
                status: :pending,
                safe_reason: nil,
                desired_meeting_version: meeting.version,
                version: export.version + 1
              )
            )

          # Fresh reconciliation obtains a current etag; no forced stale update is sent.
          terminal =
            Repo.all(
              from(m in EventMapping,
                where: m.export_id == ^export.id and not is_nil(m.tombstoned_at)
              )
            )

          if terminal != [] do
            unless Enum.all?(terminal, &(&1.status == :absent and not is_nil(&1.verified_at))),
              do: Repo.rollback(:calendar_cleanup_pending)

            export = advance_sync_generation!(export)
            synchronize!(connection, export, meeting, false, "explicit_reexport_current")
          else
            synchronize!(connection, export, meeting, false, "explicit_reexport_current")
          end
        end

        Guards.revalidate!(subject, deadline, true)
        view(Repo.get!(Export, id))
      end)
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_decision}
    end
  end

  # Caller must already own sorted Connections BEFORE the Meeting row.
  def synchronize!(connection, export, meeting, initial?, reason \\ nil) do
    if not is_nil(export.tombstoned_at) or meeting.status == :cancelled or
         not is_nil(meeting.erasure_requested_at) or not is_nil(meeting.erased_at) do
      stop!(connection, export, "source_removed")
    else
      export =
        Repo.update!(
          Ecto.Changeset.change(export,
            desired_meeting_version: meeting.version,
            author_user_ids: Enum.uniq(export.author_user_ids ++ authors!(meeting)),
            author_lineage_complete: true,
            status: :pending,
            version: export.version + 1,
            safe_reason: nil
          )
        )

      occurrences =
        Repo.all(
          from(o in MeetingOccurrence,
            where:
              o.meeting_id == ^meeting.id and
                o.tenant_id == ^meeting.tenant_id and o.meeting_version == ^meeting.version and
                o.status == :scheduled,
            order_by: [asc: o.sequence]
          )
        )

      current = Enum.map(occurrences, & &1.sequence)

      mappings =
        Repo.all(
          from(m in EventMapping,
            where: m.export_id == ^export.id,
            order_by: [asc: m.id],
            lock: "FOR UPDATE"
          )
        )

      Enum.each(mappings, fn mapping ->
        if mapping.occurrence_sequence not in current and is_nil(mapping.tombstoned_at) do
          mapping =
            Repo.update!(
              Ecto.Changeset.change(mapping,
                tombstoned_at: Budget.now(),
                status: :removing,
                desired_meeting_version: meeting.version
              )
            )

          Commands.insert!(connection, mapping, :reconcile)
        end
      end)

      Enum.each(occurrences, fn occurrence ->
        mapping =
          Enum.find(
            mappings,
            &(&1.occurrence_sequence == occurrence.sequence and
                (is_nil(&1.tombstoned_at) or &1.sync_generation == export.sync_generation))
          )

        if mapping && mapping.tombstoned_at do
          Repo.update!(
            Ecto.Changeset.change(export,
              status: :conflict,
              safe_reason: "recurrence_requires_reexport"
            )
          )
        else
          mapping =
            if mapping do
              Repo.update!(
                Ecto.Changeset.change(mapping, desired_meeting_version: meeting.version)
              )
            else
              Repo.insert!(%EventMapping{
                id: Ecto.UUID.generate(),
                tenant_id: meeting.tenant_id,
                connection_id: connection.id,
                export_id: export.id,
                meeting_id: meeting.id,
                occurrence_sequence: occurrence.sequence,
                consent_generation: connection.consent_generation,
                sync_generation: export.sync_generation,
                desired_meeting_version: meeting.version
              })
            end

          operation =
            if initial? and is_nil(mapping.external_identity_box), do: :create, else: :reconcile

          Commands.insert!(connection, mapping, operation, safe_reason: reason)
        end
      end)
    end

    :ok
  end

  def stop!(connection, export, reason) do
    if is_nil(export.tombstoned_at),
      do:
        Repo.update!(
          Ecto.Changeset.change(export,
            tombstoned_at: Budget.now(),
            status: :stopping,
            safe_reason: reason,
            version: export.version + 1
          )
        )

    mappings =
      Repo.all(
        from(m in EventMapping,
          where: m.export_id == ^export.id,
          order_by: [asc: m.id],
          lock: "FOR UPDATE"
        )
      )

    Enum.each(mappings, fn mapping ->
      mapping =
        if mapping.tombstoned_at,
          do: mapping,
          else:
            Repo.update!(
              Ecto.Changeset.change(mapping, tombstoned_at: Budget.now(), status: :removing)
            )

      unless Commands.verified_removal?(mapping),
        do: Commands.insert!(connection, mapping, :reconcile)
    end)

    :ok
  end

  def view(export),
    do: %ExportView{
      id: export.id,
      connection_id: export.connection_id,
      meeting_id: export.meeting_id,
      version: export.version,
      status: export.status,
      desired_meeting_version: export.desired_meeting_version,
      applied_meeting_version: export.applied_meeting_version,
      safe_reason: export.safe_reason,
      occurrence_count:
        Repo.aggregate(from(m in EventMapping, where: m.export_id == ^export.id), :count, :id)
    }

  def authors!(meeting) do
    unless meeting.author_lineage_complete and meeting.author_user_ids != [],
      do: Repo.rollback(:calendar_authorship_unavailable)

    meeting.author_user_ids
  end

  defp advance_sync_generation!(%Export{} = export),
    do: Repo.update!(Ecto.Changeset.change(export, sync_generation: export.sync_generation + 1))

  defp current_source!(meeting, user, version) do
    if meeting.version != version, do: Repo.rollback(:stale_version)

    unless meeting.host_user_id == user and meeting.status == :scheduled and
             is_nil(meeting.erasure_requested_at) and is_nil(meeting.erased_at),
           do: Repo.rollback(:forbidden)

    authors!(meeting)
  end

  defp version(nil), do: {:error, :version_required}
  defp version(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp version(_), do: {:error, :invalid_version}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
