defmodule CommsCore.Accounts.CalendarAuthority do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessControl,
    AccessGrant,
    CalendarActorLockQuery,
    CalendarSourceGrant,
    CalendarSourceLockQuery,
    CalendarWorkerGrant,
    CalendarWorkerLockQuery,
    ContentWriteGrant,
    User
  }

  alias CommsCore.Administration.CalendarPolicyLockQuery
  alias CommsCore.{Administration, AdmissionQuotas, Repo}

  def actor(%CalendarActorLockQuery{
        subject: subject,
        deadline_ms: deadline,
        require_step_up?: step_up
      })
      when is_integer(deadline) and is_boolean(step_up) do
    with {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} <-
           ContentWriteGrant.lock(subject, deadline),
         true <- not step_up or grant.step_up_recent? do
      {:ok, grant}
    else
      false -> {:error, :step_up_required}
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def actor(_), do: {:error, :forbidden}

  def revalidate_actor(%CalendarActorLockQuery{
        subject: subject,
        deadline_ms: deadline,
        require_step_up?: step_up
      })
      when is_integer(deadline) and is_boolean(step_up) do
    with true <- Repo.in_transaction?(),
         :ok <- budget(deadline),
         {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} <-
           AccessControl.access_grant(subject),
         :ok <- budget(deadline),
         true <- not step_up or grant.step_up_recent? do
      {:ok, grant}
    else
      false -> {:error, :forbidden}
      _ -> {:error, :forbidden}
    end
  end

  def revalidate_actor(_), do: {:error, :forbidden}

  def worker(%CalendarWorkerLockQuery{purpose: purpose, deadline_ms: deadline} = query)
      when purpose in [:export, :cleanup] and is_integer(deadline) do
    with true <- Repo.in_transaction?(),
         {:ok, tenant} <- Ecto.UUID.cast(query.tenant_id),
         {:ok, user} <- Ecto.UUID.cast(query.user_id),
         :ok <- budget(deadline),
         :ok <- AdmissionQuotas.lock_tenant(tenant),
         {:ok, _} <-
           Administration.lock_calendar_policy(%CalendarPolicyLockQuery{
             tenant_id: tenant,
             purpose: purpose,
             deadline_ms: deadline
           }),
         %User{} = identity <-
           Repo.one(
             from(u in User,
               where: u.id == ^user and u.tenant_id == ^tenant,
               lock: "FOR NO KEY UPDATE"
             )
           ),
         :ok <- budget(deadline),
         true <-
           identity.account_type == :human and
             (purpose == :cleanup or
                (identity.access_scope == :workspace and identity.status == :active)) do
      {:ok, %CalendarWorkerGrant{tenant_id: tenant, user_id: user, purpose: purpose}}
    else
      _ -> {:error, :forbidden}
    end
  end

  def worker(_), do: {:error, :forbidden}

  def source(%CalendarSourceLockQuery{deadline_ms: deadline} = query) when is_integer(deadline) do
    with true <- Repo.in_transaction?(),
         {:ok, tenant} <- Ecto.UUID.cast(value(query.subject, :tenant_id)),
         {:ok, actor_id} <- Ecto.UUID.cast(value(query.subject, :user_id)),
         hosts when is_list(hosts) and length(hosts) <= 2 <- query.connected_host_user_ids,
         true <- Enum.all?(hosts, &(match?({:ok, _}, Ecto.UUID.cast(&1)))),
         :ok <- budget(deadline),
         :ok <- AdmissionQuotas.lock_tenant(tenant),
         {:ok, _} <- Administration.lock_call_policy(tenant) do
      ids = [actor_id | hosts] |> Enum.uniq() |> Enum.sort()
      users = Repo.all(from(u in User, where: u.tenant_id == ^tenant and u.id in ^ids,
        order_by: [asc: u.id], lock: "FOR NO KEY UPDATE"))
      :ok = budget(deadline)
      if Enum.map(users, & &1.id) != ids, do: Repo.rollback(:forbidden)
      case ContentWriteGrant.lock(query.subject, deadline) do
        {:ok, %AccessGrant{account_type: :human} = actor} ->
          eligible = users |> Enum.filter(&(&1.account_type == :human and &1.access_scope == :workspace and &1.status == :active)) |> Enum.map(& &1.id)
          {:ok, %CalendarSourceGrant{actor: actor, eligible_export_user_ids: eligible}}
        _ -> {:error, :forbidden}
      end
    else
      _ -> {:error, :forbidden}
    end
  end
  def source(_), do: {:error, :forbidden}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_, _), do: nil

  defp budget(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout',$1,true), set_config('statement_timeout',$1,true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)
    :ok
  end
end
