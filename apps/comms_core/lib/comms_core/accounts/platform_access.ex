defmodule CommsCore.Accounts.PlatformAccess do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{PlatformRoleGrant, User}
  alias CommsCore.Repo

  def for_user(%User{} = user) do
    case effective_grant(user, now()) do
      %PlatformRoleGrant{} = grant -> public_access(grant)
      nil -> empty_access()
    end
  end

  def for_subject(%User{} = user) do
    case effective_grant(user, now()) do
      %PlatformRoleGrant{} = grant ->
        grant
        |> public_access()
        |> Map.put(:platform_role_grant_id, grant.id)

      nil ->
        empty_access()
        |> Map.put(:platform_role_grant_id, nil)
    end
  end

  defp effective_grant(
         %User{platform_role_grant: %PlatformRoleGrant{} = grant},
         timestamp
       ) do
    if PlatformRoleGrant.active_at?(grant, timestamp), do: grant
  end

  defp effective_grant(%User{platform_role_grant: nil}, _timestamp), do: nil

  defp effective_grant(%User{} = user, timestamp) do
    Repo.one(
      from(g in PlatformRoleGrant,
        where:
          g.user_id == ^user.id and g.tenant_id == ^user.tenant_id and
            g.expires_at > ^timestamp
      )
    )
  end

  defp public_access(%PlatformRoleGrant{} = grant),
    do: %{platform_role: grant.role, platform_role_expires_at: grant.expires_at}

  defp empty_access,
    do: %{platform_role: nil, platform_role_expires_at: nil}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
