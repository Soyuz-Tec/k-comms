defmodule CommsCore.AudioCalls.CalendarSync.IdentityFences do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Repo

  alias CommsCore.AudioCalls.CalendarSync.{
    Budget,
    Commands,
    Connection,
    IdentityFenceCommand,
    IdentityFenceReceipt,
    OAuthChallenge,
    SyncCommand
  }

  # Identity already owns the exact User parent. No Governance re-entry,
  # foreign authority lookup, Meeting lock, or provider effect is permitted here.
  def apply(%IdentityFenceCommand{} = command) do
    with true <- Repo.in_transaction?(),
         {:ok, tenant} <- Ecto.UUID.cast(command.tenant_id),
         {:ok, user} <- Ecto.UUID.cast(command.user_id),
         true <-
           command.reason in [:user_suspended, :workspace_scope_withdrawn, :governance_erasure] do
      Budget.check!(command.deadline_ms)

      connections =
        Repo.all(
          from(c in Connection,
            where: c.tenant_id == ^tenant and c.user_id == ^user,
            order_by: [asc: c.id],
            lock: "FOR UPDATE"
          )
        )

      Enum.each(connections, &fence!(&1, Atom.to_string(command.reason)))
      ids = Enum.map(connections, & &1.id)

      count =
        Repo.aggregate(
          from(c in SyncCommand,
            where:
              c.connection_id in ^ids and
                c.status in [:queued, :leased, :uncertain, :retryable, :blocked]
          ),
          :count,
          :id
        )

      Budget.check!(command.deadline_ms)

      {:ok,
       %IdentityFenceReceipt{
         fenced_connection_count: length(connections),
         pending_cleanup_command_count: count
       }}
    else
      false -> {:error, :transaction_required}
      _ -> {:error, :invalid_calendar_identity_fence}
    end
  end

  def apply(_), do: {:error, :invalid_calendar_identity_fence}

  # Tenant policy writer owns the quota/Tenant exclusion before this local-only contribution.
  def tenant(tenant) do
    if Repo.in_transaction?() do
      connections =
        Repo.all(
          from(c in Connection,
            where: c.tenant_id == ^tenant,
            order_by: [asc: c.id],
            lock: "FOR UPDATE"
          )
        )

      Enum.each(connections, &fence!(&1, "tenant_calendar_export_disabled"))
      {:ok, length(connections)}
    else
      {:error, :transaction_required}
    end
  end

  def fence!(%Connection{} = connection, reason) do
    connection =
      if connection.fenced_at do
        connection
      else
        new_fence!(connection, reason)
      end

    Repo.delete_all(from(c in OAuthChallenge, where: c.connection_id == ^connection.id))
    Commands.remove_connection!(connection, reason)
    connection
  end

  defp new_fence!(%Connection{} = connection, reason) do
    Repo.update!(
      Ecto.Changeset.change(connection,
        fenced_at: Budget.now(),
        status: if(connection.credentials_box, do: :removing, else: :removed),
        consent_generation: connection.consent_generation + 1,
        version: connection.version + 1,
        provider_grant_revocation: if(connection.credentials_box, do: :pending, else: :confirmed),
        credential_destroyed_at:
          if(connection.credentials_box,
            do: connection.credential_destroyed_at,
            else: Budget.now()
          ),
        safe_reason: reason
      )
    )
  end
end
