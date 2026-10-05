defmodule CommsCore.AudioCalls.CalendarSync.SourceContributions do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.CalendarSourceLockQuery
  alias CommsCore.AudioCalls.Meeting

  alias CommsCore.AudioCalls.CalendarSync.{
    Budget,
    Connection,
    Export,
    Exports,
    Guards,
    SourceContributionQuery,
    SourceContributionReceipt
  }

  def prepare!(%SourceContributionQuery{} = query) do
    unless Repo.in_transaction?(), do: Repo.rollback(:transaction_required)
    tenant = value(query.subject, :tenant_id)
    actor = value(query.subject, :user_id)

    snapshot =
      Repo.get_by(Meeting, id: query.meeting_id, tenant_id: tenant) || Repo.rollback(:not_found)

    # Governance precedes quota/Tenant/sorted Users and Connections, including edits with no opt-in.
    Guards.protection!(
      tenant,
      snapshot.conversation_id,
      Enum.uniq([actor, snapshot.host_user_id | snapshot.author_user_ids]),
      query.deadline_ms,
      :read
    )

    grant =
      Accounts.lock_calendar_source_users(%CalendarSourceLockQuery{
        subject: query.subject,
        connected_host_user_ids: [snapshot.host_user_id],
        deadline_ms: query.deadline_ms
      })
      |> Guards.unwrap!()

    connections =
      Repo.all(
        from(c in Connection,
          where: c.tenant_id == ^tenant and c.user_id == ^snapshot.host_user_id,
          order_by: [asc: c.id],
          lock: "FOR UPDATE"
        )
      )

    Budget.check!(query.deadline_ms)

    %SourceContributionReceipt{
      tenant_id: tenant,
      meeting_id: query.meeting_id,
      actor_user_id: actor,
      connection_ids: Enum.map(connections, & &1.id),
      eligible_export_user_ids: grant.eligible_export_user_ids,
      transaction_id: Guards.transaction_id!(),
      deadline_ms: query.deadline_ms
    }
  end

  def record!(%SourceContributionReceipt{} = receipt, %Meeting{} = meeting) do
    unless receipt.transaction_id == Guards.transaction_id!() and
             receipt.tenant_id == meeting.tenant_id and
             receipt.meeting_id == meeting.id,
           do: Repo.rollback(:calendar_contribution_invalid)

    Budget.check!(receipt.deadline_ms)

    # Deliberately NO Connection lock acquisition here: prepare! retained every row before Meeting.
    connections =
      Repo.all(
        from(c in Connection,
          where: c.id in ^receipt.connection_ids and c.tenant_id == ^receipt.tenant_id
        )
      )

    Enum.each(connections, fn connection ->
      exports =
        Repo.all(
          from(e in Export,
            where: e.connection_id == ^connection.id and e.meeting_id == ^meeting.id,
            order_by: [asc: e.id],
            lock: "FOR UPDATE"
          )
        )

      Enum.each(exports, fn export ->
        if connection.user_id in receipt.eligible_export_user_ids and connection.status == :ready and
             is_nil(connection.fenced_at) do
          Exports.synchronize!(connection, export, meeting, false)
        else
          Exports.stop!(connection, export, "eligibility_withdrawn")
        end
      end)
    end)

    Budget.check!(receipt.deadline_ms)
    :ok
  end

  def record!(_, _), do: Repo.rollback(:calendar_contribution_invalid)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
