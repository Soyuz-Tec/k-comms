defmodule CommsCore.AudioCalls.CalendarSync.Erasure do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Repo, Accounts}
  alias CommsCore.Accounts.CalendarWorkerLockQuery

  alias CommsCore.AudioCalls.CalendarSync.{
    Budget,
    Connection,
    ErasurePlan,
    ErasureReceipt,
    EventMapping,
    Export,
    Exports,
    Guards,
    IdentityFences,
    OAuthChallenge,
    SyncCommand
  }

  @active [:queued, :leased, :uncertain, :retryable, :blocked, :failed]

  def prepare(tenant, type, target) when type in [:user, :conversation, :message] do
    with true <- Repo.in_transaction?(),
         {:ok, tenant} <- Ecto.UUID.cast(tenant),
         {:ok, target} <- Ecto.UUID.cast(target) do
      deadline = Budget.deadline()
      # Tenant Governance seal is acquired before any authority or owner locks.
      Guards.protection!(
        tenant,
        nil,
        if(type == :user, do: [target], else: []),
        deadline,
        :cleanup
      )

      exports = Repo.all(scope(tenant, type, target))
      if length(exports) > 1000, do: Repo.rollback(:calendar_erasure_batch_required)

      Enum.each(exports, fn export ->
        unless export.author_lineage_complete and export.author_user_ids != [],
          do: Repo.rollback(:calendar_authorship_unavailable)

        Guards.protection!(
          tenant,
          export.conversation_id,
          export.author_user_ids,
          deadline,
          :cleanup
        )
      end)

      ids = Enum.map(exports, & &1.connection_id)
      query = from(c in Connection, where: c.tenant_id == ^tenant and c.id in ^ids)

      query =
        if type == :user,
          do:
            from(c in Connection,
              where:
                c.tenant_id == ^tenant and
                  (c.id in ^ids or c.user_id == ^target)
            ),
          else: query

      connections = Repo.all(query)

      connections
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(fn user ->
        Accounts.lock_calendar_worker(%CalendarWorkerLockQuery{
          tenant_id: tenant,
          user_id: user,
          purpose: :cleanup,
          deadline_ms: deadline
        })
        |> Guards.unwrap!()
      end)

      connection_ids = Enum.map(connections, & &1.id)

      locked =
        Repo.all(
          from(c in Connection,
            where: c.id in ^connection_ids,
            order_by: [asc: c.id],
            lock: "FOR UPDATE"
          )
        )

      Enum.each(locked, fn connection ->
        if type == :user and connection.user_id == target do
          IdentityFences.fence!(connection, "governance_erasure")
        else
          exports
          |> Enum.filter(&(&1.connection_id == connection.id))
          |> Enum.sort_by(& &1.id)
          |> Enum.each(fn initial ->
            export = Repo.one!(from(e in Export, where: e.id == ^initial.id, lock: "FOR UPDATE"))
            Exports.stop!(connection, export, "governance_erasure")
          end)
        end
      end)

      counts = counts(tenant, type, target)
      receipt = receipt!(tenant, type, target)
      verified = counts.pending_export_count == 0 and counts.pending_connection_count == 0
      if verified, do: purge_verified!(exports, locked, type, target)

      Repo.update!(
        Ecto.Changeset.change(receipt,
          status: if(verified, do: :verified, else: :pending),
          verified_at: if(verified, do: Budget.now()),
          version: receipt.version + 1
        )
      )

      Budget.check!(deadline)

      %ErasurePlan{
        pending_export_count: counts.pending_export_count,
        pending_connection_count: counts.pending_connection_count
      }
      |> then(&{:ok, &1})
    else
      false -> {:error, :transaction_required}
      _ -> {:error, :invalid_governance_target}
    end
  end

  def prepare(_, _, _), do: {:error, :invalid_governance_target}

  def pending?(tenant, type, target) when type in [:user, :conversation, :message] do
    with {:ok, tenant} <- Ecto.UUID.cast(tenant), {:ok, target} <- Ecto.UUID.cast(target) do
      result = counts(tenant, type, target)
      {:ok, result.pending_export_count > 0 or result.pending_connection_count > 0}
    else
      _ -> {:error, :invalid_governance_target}
    end
  end

  def pending?(_, _, _), do: {:error, :invalid_governance_target}

  defp counts(tenant, type, target) do
    exports = Repo.all(scope(tenant, type, target))

    pending_exports =
      Enum.count(exports, fn export ->
        export.status != :removed or is_nil(export.tombstoned_at) or is_nil(export.removed_at) or
          Repo.exists?(
            from(m in EventMapping,
              where:
                m.export_id == ^export.id and
                  (m.status != :absent or is_nil(m.verified_at) or
                     not is_nil(m.external_identity_box) or
                     not is_nil(m.etag_box) or not is_nil(m.duplicate_identities_box))
            )
          ) or
          Repo.exists?(
            from(c in SyncCommand, where: c.export_id == ^export.id and c.status in ^@active)
          )
      end)

    pending_connections =
      if type == :user do
        Repo.aggregate(
          from(c in Connection,
            where:
              c.tenant_id == ^tenant and c.user_id == ^target and
                (c.status != :removed or is_nil(c.credential_destroyed_at) or
                   not is_nil(c.credentials_box) or
                   not is_nil(c.external_identity_box) or
                   c.provider_grant_revocation != :confirmed)
          ),
          :count,
          :id
        )
      else
        0
      end

    %{pending_export_count: pending_exports, pending_connection_count: pending_connections}
  end

  defp purge_verified!(exports, connections, type, target) do
    ids = Enum.map(exports, & &1.id)
    Repo.delete_all(from(c in SyncCommand, where: c.export_id in ^ids))
    Repo.delete_all(from(m in EventMapping, where: m.export_id in ^ids))
    Repo.delete_all(from(e in Export, where: e.id in ^ids))

    if type == :user do
      Enum.each(Enum.filter(connections, &(&1.user_id == target)), fn connection ->
        Repo.delete_all(from(c in OAuthChallenge, where: c.connection_id == ^connection.id))
        Repo.delete_all(from(c in SyncCommand, where: c.connection_id == ^connection.id))
        delete_connection!(connection)
      end)
    end
  end

  defp delete_connection!(%Connection{} = connection), do: Repo.delete!(connection)

  defp scope(tenant, :user, target),
    do:
      from(e in Export,
        where:
          e.tenant_id == ^tenant and
            (e.user_id == ^target or ^target in e.author_user_ids),
        order_by: [asc: e.id],
        limit: 1001
      )

  defp scope(tenant, :conversation, target),
    do:
      from(e in Export,
        where: e.tenant_id == ^tenant and e.conversation_id == ^target,
        order_by: [asc: e.id],
        limit: 1001
      )

  defp scope(tenant, :message, _target),
    do: from(e in Export, where: e.tenant_id == ^tenant and false)

  defp receipt!(tenant, type, target) do
    fingerprint =
      :crypto.hash(
        :sha256,
        "calendar-erasure-v1\0" <> tenant <> "\0" <> Atom.to_string(type) <> "\0" <> target
      )

    Repo.one(
      from(r in ErasureReceipt,
        where:
          r.tenant_id == ^tenant and r.target_type == ^type and
            r.target_fingerprint == ^fingerprint,
        lock: "FOR UPDATE"
      )
    ) ||
      Repo.insert!(%ErasureReceipt{
        tenant_id: tenant,
        target_type: type,
        target_fingerprint: fingerprint
      })
  end
end
