defmodule CommsCore.Accounts.ReleaseInventory do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{
    AuthChallenge,
    Device,
    FederatedIdentity,
    MfaFactor,
    MemberWorkspace,
    ScimResource,
    Session,
    User
  }

  @spec enterprise_identity_hazard_count(module()) :: non_neg_integer()
  def enterprise_identity_hazard_count(repo) when is_atom(repo) do
    timestamp = DateTime.utc_now()

    # Retained pending enrollments and SCIM tombstones still depend on the
    # enterprise owner. Count persisted state, independently of user status.
    # A legacy refresh may ignore an enhanced session's absolute bound, so its
    # live sliding deadline remains a hazard until expiry or revocation.
    repo.aggregate(MfaFactor, :count) +
      repo.aggregate(FederatedIdentity, :count) +
      repo.aggregate(ScimResource, :count) +
      repo.aggregate(
        from(challenge in AuthChallenge,
          where: is_nil(challenge.consumed_at) and challenge.expires_at > ^timestamp
        ),
        :count
      ) +
      repo.aggregate(
        from(session in Session,
          where:
            is_nil(session.revoked_at) and session.expires_at > ^timestamp and
              (session.authentication_method != "password" or not is_nil(session.mfa_verified_at))
        ),
        :count
      )
  end

  @spec member_workspace_hazard_count(module()) :: non_neg_integer()
  def member_workspace_hazard_count(repo) when is_atom(repo),
    do: repo.aggregate(MemberWorkspace, :count)

  @spec tenant_fingerprint_fragment(module(), Ecto.UUID.t()) :: %{
          users: [Ecto.UUID.t()],
          sessions: [Ecto.UUID.t()],
          devices: [Ecto.UUID.t()],
          member_workspaces: [Ecto.UUID.t()]
        }
  def tenant_fingerprint_fragment(repo, tenant_id)
      when is_atom(repo) and is_binary(tenant_id) do
    %{
      users:
        repo.all(
          from(user in User,
            where: user.tenant_id == ^tenant_id,
            select: user.id
          )
        ),
      sessions:
        repo.all(
          from(session in Session,
            where: session.tenant_id == ^tenant_id,
            select: session.id
          )
        ),
      member_workspaces:
        repo.all(
          from(workspace in MemberWorkspace,
            where: workspace.tenant_id == ^tenant_id,
            select: workspace.id
          )
        ),
      devices:
        repo.all(
          from(device in Device,
            where: device.tenant_id == ^tenant_id,
            select: device.id
          )
        )
    }
  end
end
