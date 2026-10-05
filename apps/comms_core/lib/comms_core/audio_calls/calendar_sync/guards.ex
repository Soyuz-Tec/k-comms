defmodule CommsCore.AudioCalls.CalendarSync.Guards do
  @moduledoc false
  alias CommsCore.{Accounts, Administration, Repo}
  alias CommsCore.Accounts.{CalendarActorLockQuery, CalendarWorkerLockQuery}
  alias CommsCore.Administration.CalendarPolicyLockQuery
  alias CommsCore.AudioCalls.CalendarSync.{Budget, ProtectionPort, ProtectionQuery}

  def protection!(tenant, conversation, authors, deadline, purpose) do
    Budget.check!(deadline)

    receipt =
      unwrap!(
        ProtectionPort.protection(%ProtectionQuery{
          tenant_id: tenant,
          conversation_id: conversation,
          author_user_ids: Enum.uniq(authors),
          deadline_ms: deadline
        })
      )

    if purpose != :read and receipt.held?, do: Repo.rollback(:calendar_legal_hold)

    if purpose == :export and receipt.capture_blocked?,
      do: Repo.rollback(:calendar_export_blocked)

    receipt
  end

  def actor!(subject, deadline, proof \\ false) do
    Accounts.lock_calendar_actor(actor_query(subject, deadline, proof)) |> unwrap!()
  end

  def revalidate!(subject, deadline, proof \\ false) do
    Accounts.revalidate_calendar_actor(actor_query(subject, deadline, proof)) |> unwrap!()
  end

  def worker!(connection, deadline, purpose) do
    Accounts.lock_calendar_worker(%CalendarWorkerLockQuery{
      tenant_id: connection.tenant_id,
      user_id: connection.user_id,
      purpose: purpose,
      deadline_ms: deadline
    })
    |> unwrap!()
  end

  def policy!(tenant, deadline, purpose) do
    Administration.lock_calendar_policy(%CalendarPolicyLockQuery{
      tenant_id: tenant,
      purpose: purpose,
      deadline_ms: deadline
    })
    |> unwrap!()
  end

  def transaction_id! do
    unless Repo.in_transaction?(), do: Repo.rollback(:transaction_required)
    %{rows: [[id]]} = Repo.query!("SELECT txid_current()", [])
    id
  end

  def unwrap!({:ok, result}), do: result
  def unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp actor_query(subject, deadline, proof),
    do: %CalendarActorLockQuery{
      subject: subject,
      deadline_ms: deadline,
      require_step_up?: proof
    }
end
