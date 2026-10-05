defmodule CommsCore.Accounts.FederationGrants do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Accounts.{AccessGrant, ContentWriteGrant, FederationActorLockQuery, User}
  alias CommsCore.{Administration, AdmissionQuotas, Repo}
  @spec lock(FederationActorLockQuery.t()) :: {:ok, AccessGrant.t()} | {:error, atom()}
  def lock(%FederationActorLockQuery{
        subject: subject,
        local_participant_user_ids: participants,
        deadline: deadline
      })
      when is_map(subject) and is_list(participants) and length(participants) <= 100 and
             is_integer(deadline) do
    tenant = Map.get(subject, :tenant_id, Map.get(subject, "tenant_id"))
    actor = Map.get(subject, :user_id, Map.get(subject, "user_id"))
    users = [actor | participants] |> Enum.uniq() |> Enum.sort()

    with true <- Repo.in_transaction?(),
         true <- deadline <= System.monotonic_time(:millisecond) + 15_000,
         {:ok, ^tenant} <- Ecto.UUID.cast(tenant),
         true <- Enum.all?(users, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      budget!(deadline)
      :ok = AdmissionQuotas.lock_tenant(tenant)
      budget!(deadline)

      with {:ok, _} <- Administration.lock_call_policy(tenant) do
        budget!(deadline)

        retained =
          Repo.all(
            from(u in User,
              where:
                u.tenant_id == ^tenant and u.id in ^users and
                  u.status == :active and u.account_type == :human and
                  u.access_scope == :workspace,
              order_by: u.id,
              select: u.id,
              lock: "FOR NO KEY UPDATE"
            )
          )

        budget!(deadline)

        if retained == users,
          do: ContentWriteGrant.lock(subject, deadline),
          else: {:error, :forbidden}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  def lock(_), do: {:error, :forbidden}

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    :ok
  end
end
