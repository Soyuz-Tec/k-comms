defmodule CommsCore.AudioCalls.CalendarSync.Commands do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.AudioCalls.CalendarSync.{Budget, EventMapping, Export, SyncCommand}
  alias CommsCore.{Repo, RuntimePorts}

  def available? do
    worker = RuntimePorts.job_worker!(:calendar_sync)
    Code.ensure_loaded?(worker) and function_exported?(worker, :new, 1)
  rescue
    _ -> false
  end

  def insert!(connection, mapping, operation, attrs \\ []) do
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
        existing

      nil ->
        command =
          Repo.insert!(
            struct!(
              SyncCommand,
              Keyword.merge(
                [
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
                ],
                attrs
              )
            )
          )

        enqueue!(command)
        command
    end
  end

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

        # Reconcile first, including formerly absent mappings with an expired
        # lease whose remote create acknowledgement may have been lost.
        insert!(connection, mapping, :reconcile)
      end)
    end)

    if exports == [], do: insert!(connection, nil, :revoke)
    :ok
  end
end
