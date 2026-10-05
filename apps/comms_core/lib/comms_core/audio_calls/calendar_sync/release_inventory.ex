defmodule CommsCore.AudioCalls.CalendarSync.ReleaseInventory do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Repo

  alias CommsCore.AudioCalls.CalendarSync.{
    Connection,
    OAuthChallenge,
    Export,
    EventMapping,
    SyncCommand,
    ErasureReceipt
  }

  @schemas [
    calendar_connections: Connection,
    calendar_oauth_challenges: OAuthChallenge,
    calendar_exports: Export,
    calendar_event_mappings: EventMapping,
    calendar_sync_commands: SyncCommand,
    calendar_erasure_receipts: ErasureReceipt
  ]
  def hazard_count do
    Enum.reduce(@schemas, 0, fn {table, schema}, count ->
      case Repo.query!("SELECT to_regclass($1) IS NOT NULL", ["public." <> Atom.to_string(table)]).rows do
        [[true]] -> count + Repo.aggregate(schema, :count, :id)
        _ -> raise "Calendar rollback inventory unavailable"
      end
    end) + CommsCore.Administration.rollback_calendar_policy_hazard_count()
  end

  def erasure_hazard_count do
    Repo.aggregate(ErasureReceipt, :count, :id) +
      Repo.aggregate(from(e in Export, where: not is_nil(e.tombstoned_at)), :count, :id)
  end

  def tenant_fingerprint_fragment(repo, tenant) do
    Map.new(@schemas, fn {name, schema} ->
      {name, repo.all(from(row in schema, where: row.tenant_id == ^tenant, select: row.id))}
    end)
  end
end
