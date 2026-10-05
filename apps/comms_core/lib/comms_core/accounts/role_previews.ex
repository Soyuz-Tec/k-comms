defmodule CommsCore.Accounts.RolePreviews do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessControl,
    RolePermissions,
    SessionAuthority,
    User,
    UserRoleChangePreviewView
  }

  alias CommsCore.{AdmissionQuotas, Repo}

  def catalog(subject) when is_map(subject) do
    transaction(subject, [], false, fn _users, _grant -> RolePermissions.catalog() end)
  end

  def catalog(_), do: {:error, :forbidden}

  def preview(user_id, attrs, subject) when is_map(attrs) and is_map(subject) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         {:ok, role} <- RolePermissions.normalize_role(value(attrs, :role)),
         {:ok, version} <- version(value(attrs, :version)) do
      transaction(subject, [user_id], true, fn users, grant ->
        target = Enum.find(users, &(&1.id == user_id))

        unless target && target.account_type == :human && target.status != :deleted,
          do: Repo.rollback(:not_found)

        if target.lock_version != version, do: Repo.rollback(:stale_version)

        allowed? =
          RolePermissions.authorize_change(grant.role, target.role, role, target.access_scope) ==
            :ok

        blockers = if allowed?, do: [], else: [:forbidden]
        blockers = blockers ++ last_owner_blockers(target, role)
        current = RolePermissions.capabilities(target.role, target.access_scope)
        requested = RolePermissions.capabilities(role, target.access_scope)

        %UserRoleChangePreviewView{
          target_id: target.id,
          current_role: target.role,
          requested_role: role,
          current_version: target.lock_version,
          target_status: target.status,
          target_access_scope: target.access_scope,
          role_policy_allows: allowed?,
          blockers: blockers,
          added: requested -- current,
          removed: current -- requested
        }
      end)
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def preview(_, _, _), do: {:error, :forbidden}

  defp transaction(subject, target_ids, require_step_up?, project) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(value(subject, :tenant_id)),
         {:ok, actor_id} <- Ecto.UUID.cast(value(subject, :user_id)),
         {:ok, _grant} <- authorize(subject, require_step_up?) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          SessionAuthority.ensure_budget(deadline)
          :ok = AdmissionQuotas.lock_tenant(tenant_id)

          case SessionAuthority.lock_active_tenant(tenant_id, deadline) do
            {:ok, _} -> :ok
            _ -> Repo.rollback(:forbidden)
          end

          users =
            Enum.map(Enum.sort(Enum.uniq([actor_id | target_ids])), fn id ->
              SessionAuthority.ensure_budget(deadline)

              Repo.one(
                from(user in User,
                  where: user.id == ^id and user.tenant_id == ^tenant_id,
                  lock: "FOR NO KEY UPDATE"
                )
              ) || Repo.rollback(if id == actor_id, do: :forbidden, else: :not_found)
            end)

          case SessionAuthority.lock(subject, deadline) do
            {:ok, _} -> :ok
            _ -> Repo.rollback(:forbidden)
          end

          grant = authorize!(subject, require_step_up?)
          result = project.(users, grant)
          SessionAuthority.ensure_budget(deadline)
          authorize!(subject, require_step_up?)
          SessionAuthority.ensure_budget(deadline)
          result
        end,
        timeout: 20_000
      )
    else
      :error -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  defp authorize(subject, require_step_up?) do
    case AccessControl.access_grant(subject) do
      {:ok, %{account_type: :human, access_scope: :workspace, role: role} = grant}
      when role in [:owner, :admin] ->
        if require_step_up? and not grant.step_up_recent?,
          do: {:error, :step_up_required},
          else: {:ok, grant}

      _ ->
        {:error, :forbidden}
    end
  end

  defp authorize!(subject, step_up?) do
    case authorize(subject, step_up?) do
      {:ok, grant} -> grant
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp last_owner_blockers(
         %User{role: :owner, status: :active, account_type: :human, access_scope: :workspace} =
           target,
         role
       )
       when role != :owner do
    remaining =
      Repo.aggregate(
        from(user in User,
          where:
            user.tenant_id == ^target.tenant_id and user.id != ^target.id and
              user.role == :owner and user.status == :active and user.account_type == :human and
              user.access_scope == :workspace
        ),
        :count
      )

    if remaining == 0, do: [:last_owner_required], else: []
  end

  defp last_owner_blockers(_, _), do: []
  defp version(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp version(value) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :version_required}
    end
  end

  defp version(_), do: {:error, :version_required}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
