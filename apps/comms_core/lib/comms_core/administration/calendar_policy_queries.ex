defmodule CommsCore.Administration.CalendarPolicyQueries do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Administration.{CalendarPolicy, CalendarPolicyLockQuery, Tenant, TenantSettings}
  alias CommsCore.Repo

  def lock(%CalendarPolicyLockQuery{purpose: purpose, deadline_ms: deadline} = query)
      when purpose in [:export, :cleanup] and is_integer(deadline) do
    with true <- Repo.in_transaction?(),
         {:ok, tenant_id} <- Ecto.UUID.cast(query.tenant_id),
         :ok <- budget(deadline),
         %Tenant{} = tenant <-
           Repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR SHARE")),
         :ok <- budget(deadline),
         true <- purpose == :cleanup or tenant.status == :active do
      settings = Repo.one(from(s in TenantSettings, where: s.tenant_id == ^tenant_id))
      :ok = budget(deadline)

      {:ok,
       %CalendarPolicy{
         tenant_id: tenant_id,
         tenant_active?: tenant.status == :active,
         export_allowed?:
           tenant.status == :active and settings != nil and settings.allow_calendar_export,
         version: if(settings, do: settings.calendar_export_policy_version, else: 1)
       }}
    else
      false -> {:error, :forbidden}
      _ -> {:error, :forbidden}
    end
  end

  def lock(_), do: {:error, :forbidden}

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
