defmodule CommsCore.Accounts.GuestIdentities.ParentAuthority do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{
    GuestIdentityParentsLockQuery,
    GuestIdentityParentsLockReceipt,
    SessionAuthority,
    User
  }

  alias CommsCore.{AdmissionQuotas, Repo}

  def lock(%GuestIdentityParentsLockQuery{
        tenant_id: tenant_id,
        user_ids: user_ids,
        deadline: deadline,
        require_active_tenant: active?
      })
      when is_list(user_ids) and length(user_ids) <= 100_000 and
             is_integer(deadline) and is_boolean(active?) do
    if Repo.in_transaction?() do
      deadline = min(deadline, deadline())

      with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
           true <- Enum.all?(user_ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
           :ok <- SessionAuthority.ensure_budget(deadline),
           :ok <- remember_deadline(deadline),
           :ok <- AdmissionQuotas.lock_tenant(tenant_id),
           :ok <- SessionAuthority.ensure_budget(deadline),
           :ok <- lock_tenant(tenant_id, active?, deadline) do
        ids =
          user_ids
          |> Enum.map(fn id ->
            {:ok, id} = Ecto.UUID.cast(id)
            id
          end)
          |> Enum.uniq()
          |> Enum.sort()

        Enum.each(ids, fn id ->
          SessionAuthority.ensure_budget(deadline)

          case Repo.one(
                 from(user in User,
                   where: user.id == ^id and user.tenant_id == ^tenant_id,
                   lock: "FOR NO KEY UPDATE",
                   select: user.id
                 )
               ) do
            ^id -> :ok
            _ -> Repo.rollback(:forbidden)
          end

          SessionAuthority.ensure_budget(deadline)
        end)

        {:ok, %GuestIdentityParentsLockReceipt{tenant_id: tenant_id, user_ids: ids}}
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock(_), do: {:error, :forbidden}

  def deadline do
    %{rows: [[saved]]} =
      Repo.query!("SELECT current_setting('k_comms.guest_authority_deadline', true)", [])

    case Integer.parse(saved || "") do
      {value, ""} -> value
      _ -> System.monotonic_time(:millisecond) + 15_000
    end
  end

  def ensure_budget, do: SessionAuthority.ensure_budget(deadline())

  defp remember_deadline(deadline) do
    deadline = min(deadline, deadline())

    Repo.query!(
      "SELECT set_config('k_comms.guest_authority_deadline', $1, true)",
      [Integer.to_string(deadline)]
    )

    SessionAuthority.ensure_budget(deadline)
  end

  defp lock_tenant(tenant_id, true, deadline) do
    case SessionAuthority.lock_active_tenant(tenant_id, deadline) do
      {:ok, _tenant} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  # Cleanup remains available for expired identities and inactive tenants.
  # The shared admission prefix still precedes every retained User parent.
  defp lock_tenant(_tenant_id, false, _deadline), do: :ok
end
