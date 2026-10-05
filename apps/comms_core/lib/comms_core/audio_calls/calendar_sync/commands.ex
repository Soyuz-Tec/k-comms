defmodule CommsCore.AudioCalls.CalendarSync.Commands do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.AudioCalls.CalendarSync.{Budget, Connection, EventMapping, Export, SyncCommand}
  alias CommsCore.{Repo, RuntimePorts}

  def available? do
    worker = RuntimePorts.job_worker!(:calendar_sync)
    Code.ensure_loaded?(worker) and function_exported?(worker, :new, 1)
  rescue
    _ -> false
  end

  def insert!(%Connection{} = connection, mapping, operation, attrs \\ []) do
    lookup =
      from(c in SyncCommand,
        where:
          c.connection_id == ^connection.id and
            c.operation == ^operation and c.consent_generation == ^connection.consent_generation and
            c.credential_generation == ^connection.credential_generation
      )

    lookup =
      if mapping do
        from(c in lookup,
          where:
            c.mapping_id == ^mapping.id and
              c.meeting_version == ^mapping.desired_meeting_version and
              c.sync_generation == ^mapping.sync_generation
        )
      else
        from(c in lookup, where: is_nil(c.mapping_id))
      end

    case Repo.one(lookup) do
      %SyncCommand{} = existing ->
        # Only explicit reconciliation/update/removal may wake a completed intent.
        # An uncertain create is never reset to its first attempt.
        if operation != :create and existing.status in [:done, :blocked, :failed] do
          command =
            update_command!(existing,
              status: :queued,
              completed_at: nil,
              available_at: Budget.now(),
              attempt: 0,
              lease_id: nil,
              lease_expires_at: nil,
              safe_reason: Keyword.get(attrs, :safe_reason)
            )

          enqueue!(command)
          command
        else
          existing
        end

      nil ->
        command =
          Repo.insert!(
            Ecto.Changeset.change(
              %SyncCommand{
                id: Ecto.UUID.generate(),
                tenant_id: connection.tenant_id,
                connection_id: connection.id,
                export_id: if(mapping, do: mapping.export_id),
                mapping_id: if(mapping, do: mapping.id),
                operation: operation,
                consent_generation: connection.consent_generation,
                credential_generation: connection.credential_generation,
                sync_generation: if(mapping, do: mapping.sync_generation),
                meeting_version: if(mapping, do: mapping.desired_meeting_version),
                available_at: Budget.now()
              },
              Map.new(attrs)
            )
          )

        enqueue!(command)
        command
    end
  end

  defp update_command!(%SyncCommand{} = command, attrs),
    do: Repo.update!(Ecto.Changeset.change(command, attrs))

  def enqueue!(%SyncCommand{} = command) do
    worker = RuntimePorts.job_worker!(:calendar_sync)
    args = %{"command_id" => command.id, "consent_generation" => command.consent_generation}

    case args |> worker.new() |> Oban.insert() do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback(:calendar_worker_unavailable)
    end
  rescue
    _ -> Repo.rollback(:calendar_worker_unavailable)
  end

  # Sole recreate entry: the caller just retained the parent/mapping locks and
  # a same-principal scoped absence proof after an explicit actor decision.
  def create_after_verified_absence!(connection, mapping) do
    unless Repo.in_transaction?() and not is_nil(mapping.verified_at) and
             is_nil(mapping.tombstoned_at) and
             is_nil(connection.fenced_at) and is_nil(mapping.external_identity_box),
           do: Repo.rollback(:calendar_reexport_proof_required)

    command = insert!(connection, mapping, :create)

    if command.status in [:done, :blocked, :failed, :uncertain, :retryable] do
      command =
        update_command!(command,
          status: :queued,
          attempt: 0,
          completed_at: nil,
          lease_id: nil,
          lease_expires_at: nil,
          available_at: Budget.now(),
          safe_reason: nil
        )

      enqueue!(command)
      command
    else
      command
    end
  end

  def remove_connection!(connection, reason) do
    timestamp = Budget.now()

    exports =
      Repo.all(
        from(e in Export,
          where:
            e.tenant_id == ^connection.tenant_id and
              e.connection_id == ^connection.id,
          order_by: [asc: e.id],
          lock: "FOR UPDATE"
        )
      )

    Enum.each(exports, fn export ->
      if is_nil(export.tombstoned_at) do
        Repo.update!(
          Ecto.Changeset.change(export,
            tombstoned_at: timestamp,
            status: :stopping,
            version: export.version + 1,
            safe_reason: reason
          )
        )
      end

      mappings =
        Repo.all(
          from(m in EventMapping,
            where:
              m.tenant_id == ^connection.tenant_id and
                m.export_id == ^export.id,
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
                Ecto.Changeset.change(mapping, tombstoned_at: timestamp, status: :removing)
              )

        # Reuse only a proof committed after the immutable tombstone, with all
        # prior intents terminal. An unknown or formerly unfenced absence still
        # requires scoped reconciliation; repeating preparation cannot reopen a
        # completed cleanup and prevent Governance from purging private rows.
        unless verified_removal?(mapping), do: insert!(connection, mapping, :reconcile)
      end)
    end)

    if exports == [] and
         not (connection.status == :removed and is_nil(connection.credentials_box) and
                connection.provider_grant_revocation in [:confirmed, :external_unconfirmed]),
       do: insert!(connection, nil, :revoke)

    :ok
  end

  def verified_removal?(%EventMapping{} = mapping) do
    mapping.status == :absent and not is_nil(mapping.tombstoned_at) and
      not is_nil(mapping.verified_at) and
      DateTime.compare(mapping.verified_at, mapping.tombstoned_at) != :lt and
      is_nil(mapping.external_identity_box) and is_nil(mapping.etag_box) and
      is_nil(mapping.duplicate_identities_box) and
      not Repo.exists?(
        from(c in SyncCommand,
          where: c.mapping_id == ^mapping.id and c.status != :done
        )
      )
  end
end
