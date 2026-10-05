defmodule CommsCore.Accounts.MemberWorkspaces do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessControl,
    ContentWriteGrant,
    Device,
    MemberContactView,
    MemberWorkspace,
    MemberWorkspaceView,
    User
  }

  alias CommsCore.{Administration, AdmissionQuotas, Repo}

  @limits %{contacts: 500, groups: 20, members_per_group: 50}
  @allowed_fields ~w(version contact_ids groups)

  @spec get(map()) :: {:ok, MemberWorkspaceView.t()} | {:error, :forbidden}
  def get(subject) do
    with {:ok, grant} <- workspace_grant(subject) do
      result = project(record(grant), grant)
      with {:ok, _current} <- workspace_grant(subject), do: {:ok, result}
    end
  end

  @spec replace(map(), map()) :: {:ok, MemberWorkspaceView.t()} | {:error, atom()}
  def replace(attrs, subject) when is_map(attrs) do
    with {:ok, _grant} <- workspace_grant(subject),
         {:ok, contacts, groups, version} <- replacement(attrs) do
      transaction(subject, contacts, fn grant, current ->
        require_version!(version, current)
        persist!(current, grant, %{contact_ids: contacts, contact_groups: %{"items" => groups}})
      end)
    end
  end

  def replace(_, _), do: {:error, :invalid_member_workspace}

  @spec onboarding(map(), map()) :: {:ok, MemberWorkspaceView.t()} | {:error, atom()}
  def onboarding(attrs, subject) when is_map(attrs) do
    with {:ok, _grant} <- workspace_grant(subject),
         {:ok, version} <- version(attrs),
         action when action in ["dismiss", "resume", "reset"] <- value(attrs, :action),
         true <- Enum.all?(Map.keys(attrs), &(to_string(&1) in ~w(version action))) do
      transaction(subject, [], fn grant, current ->
        require_version!(version, current)

        changes =
          case action do
            "dismiss" -> %{onboarding_dismissed_at: now()}
            "resume" -> %{onboarding_dismissed_at: nil}
            "reset" -> %{onboarding_dismissed_at: nil, profile_reviewed_at: nil}
          end

        persist!(current, grant, changes)
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_onboarding_action}
    end
  end

  def onboarding(_, _), do: {:error, :invalid_onboarding_action}

  # Called only after a successful profile update in the same owner transaction.
  def profile_reviewed!(
        %User{account_type: :human, access_scope: :workspace, status: :active} = user
      ) do
    if not Repo.in_transaction?(), do: raise("profile review requires the profile transaction")
    grant = %{tenant_id: user.tenant_id, user_id: user.id}
    current = locked_record(grant)
    persist!(current, grant, %{profile_reviewed_at: now()})
    :ok
  end

  def profile_reviewed!(%User{}), do: :ok

  # The governance owner retains all canonical User parents before this sweep.
  # Updating versions prevents a stale client from reintroducing erased IDs.
  def erase_user!(tenant_id, user_id) do
    if not Repo.in_transaction?(), do: raise("member erasure requires a transaction")

    Repo.delete_all(
      from(workspace in MemberWorkspace,
        where: workspace.tenant_id == ^tenant_id and workspace.user_id == ^user_id
      )
    )

    Repo.all(
      from(workspace in MemberWorkspace,
        where: workspace.tenant_id == ^tenant_id and ^user_id in workspace.contact_ids,
        order_by: [asc: workspace.user_id],
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(fn workspace ->
      contacts = Enum.reject(workspace.contact_ids, &(&1 == user_id))

      groups =
        Enum.map(workspace.contact_groups["items"], fn group ->
          Map.update!(group, "member_ids", &Enum.reject(&1, fn id -> id == user_id end))
        end)

      workspace
      |> MemberWorkspace.changeset(%{
        contact_ids: contacts,
        contact_groups: %{"items" => groups},
        lock_version: workspace.lock_version + 1
      })
      |> Repo.update!()
    end)

    :ok
  end

  defp transaction(subject, contact_ids, operation) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Repo.transaction(
      fn ->
        budget!(deadline)
        tenant_id = value(subject, :tenant_id)
        actor_id = value(subject, :user_id)
        if actor_id in contact_ids, do: Repo.rollback(:contact_unavailable)
        AdmissionQuotas.lock_tenant(tenant_id)
        budget!(deadline)

        case Administration.lock_call_policy(tenant_id) do
          {:ok, _policy} -> :ok
          _ -> Repo.rollback(:forbidden)
        end

        # Retain all actor/target parents in one canonical order. Taking actor
        # first would deadlock two people adding one another concurrently.
        ids = Enum.sort(Enum.uniq([actor_id | contact_ids]))

        users =
          Repo.all(
            from(user in User,
              where:
                user.tenant_id == ^tenant_id and user.id in ^ids and
                  user.account_type == :human and user.access_scope == :workspace and
                  user.status == :active,
              order_by: [asc: user.id],
              select: user.id,
              lock: "FOR NO KEY UPDATE"
            )
          )

        if users != ids, do: Repo.rollback(:contact_unavailable)
        budget!(deadline)

        grant =
          case ContentWriteGrant.lock(subject, deadline) do
            {:ok, grant} -> grant
            _ -> Repo.rollback(:forbidden)
          end

        if grant.account_type != :human or grant.access_scope != :workspace,
          do: Repo.rollback(:forbidden)

        current = locked_record(grant)
        updated = operation.(grant, current)
        budget!(deadline)
        result = project(updated, grant)
        budget!(deadline)

        case workspace_grant(subject) do
          {:ok, _grant} -> :ok
          _ -> Repo.rollback(:forbidden)
        end

        budget!(deadline)
        result
      end,
      timeout: 20_000
    )
  end

  defp workspace_grant(subject) do
    case AccessControl.access_grant(subject) do
      {:ok, %{account_type: :human, access_scope: :workspace} = grant} -> {:ok, grant}
      _ -> {:error, :forbidden}
    end
  end

  defp record(grant),
    do:
      Repo.one(
        from(workspace in MemberWorkspace,
          where: workspace.tenant_id == ^grant.tenant_id and workspace.user_id == ^grant.user_id
        )
      )

  defp locked_record(grant),
    do:
      Repo.one(
        from(workspace in MemberWorkspace,
          where: workspace.tenant_id == ^grant.tenant_id and workspace.user_id == ^grant.user_id,
          lock: "FOR UPDATE"
        )
      )

  defp persist!(current, grant, changes) do
    state = current || %MemberWorkspace{tenant_id: grant.tenant_id, user_id: grant.user_id}
    next = if current, do: current.lock_version + 1, else: 1
    changes = Map.put(changes, :lock_version, next)

    case state |> MemberWorkspace.changeset(changes) |> Repo.insert_or_update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> Repo.rollback(:invalid_member_workspace)
    end
  end

  defp require_version!(version, current) do
    actual = if current, do: current.lock_version, else: 0
    if version != actual, do: Repo.rollback(:stale_version)
  end

  defp project(current, grant) do
    current = current || %MemberWorkspace{}

    people =
      Repo.all(
        from(user in User,
          where:
            user.tenant_id == ^grant.tenant_id and user.id in ^current.contact_ids and
              user.account_type == :human and user.access_scope == :workspace and
              user.status == :active,
          order_by: [asc: user.display_name, asc: user.id],
          select: %{id: user.id, display_name: user.display_name}
        )
      )

    ids = MapSet.new(Enum.map(people, & &1.id))

    groups =
      Enum.map(current.contact_groups["items"], fn group ->
        %{
          id: group["id"],
          name: group["name"],
          member_ids: Enum.filter(group["member_ids"], &MapSet.member?(ids, &1))
        }
      end)

    %MemberWorkspaceView{
      version: if(current.id, do: current.lock_version, else: 0),
      contacts: Enum.map(people, &struct!(MemberContactView, &1)),
      groups: groups,
      onboarding: %{
        dismissed_at: current.onboarding_dismissed_at,
        profile_reviewed_at: current.profile_reviewed_at,
        active_devices:
          Repo.aggregate(
            from(device in Device,
              where:
                device.tenant_id == ^grant.tenant_id and device.user_id == ^grant.user_id and
                  is_nil(device.revoked_at)
            ),
            :count
          ),
        has_teammates:
          Repo.exists?(
            from(user in User,
              where:
                user.tenant_id == ^grant.tenant_id and user.id != ^grant.user_id and
                  user.account_type == :human and user.access_scope == :workspace and
                  user.status == :active
            )
          )
      },
      limits: @limits,
      observed_at: now()
    }
  end

  defp replacement(attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(to_string(&1) in @allowed_fields)),
         {:ok, version} <- version(attrs),
         contacts when is_list(contacts) <- value(attrs, :contact_ids),
         true <- length(contacts) <= @limits.contacts,
         {:ok, contacts} <- uuids(contacts),
         groups when is_list(groups) <- value(attrs, :groups),
         true <- length(groups) <= @limits.groups,
         {:ok, groups} <- groups(groups, MapSet.new(contacts)) do
      {:ok, contacts, groups, version}
    else
      {:error, :version_required} = error -> error
      _ -> {:error, :invalid_member_workspace}
    end
  end

  defp groups(groups, contacts) do
    parsed =
      Enum.map(groups, fn group ->
        with true <- is_map(group),
             true <- Enum.all?(Map.keys(group), &(to_string(&1) in ~w(id name member_ids))),
             {:ok, id} <- Ecto.UUID.cast(value(group, :id)),
             name when is_binary(name) <- value(group, :name),
             name <- String.trim(name),
             true <- String.length(name) in 1..80,
             members when is_list(members) <- value(group, :member_ids),
             true <- length(members) <= @limits.members_per_group,
             {:ok, members} <- uuids(members),
             true <- Enum.all?(members, &MapSet.member?(contacts, &1)) do
          {:ok, %{"id" => id, "name" => name, "member_ids" => members}}
        else
          _ -> {:error, :invalid_member_workspace}
        end
      end)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) do
      result = Enum.map(parsed, &elem(&1, 1))

      if length(Enum.uniq_by(result, & &1["id"])) == length(result),
        do: {:ok, result},
        else: {:error, :invalid_member_workspace}
    else
      {:error, :invalid_member_workspace}
    end
  end

  defp uuids(values) do
    parsed = Enum.map(values, &Ecto.UUID.cast/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) do
      result = Enum.map(parsed, &elem(&1, 1))

      if length(Enum.uniq(result)) == length(result),
        do: {:ok, Enum.sort(result)},
        else: {:error, :invalid_member_workspace}
    else
      {:error, :invalid_member_workspace}
    end
  end

  defp version(attrs) do
    case value(attrs, :version) do
      version when is_integer(version) and version >= 0 -> {:ok, version}
      _ -> {:error, :version_required}
    end
  end

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [Integer.to_string(remaining) <> "ms"]
    )

    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)
    :ok
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
