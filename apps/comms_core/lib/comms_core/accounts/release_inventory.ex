defmodule CommsCore.Accounts.ReleaseInventory do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, User}

  @spec tenant_fingerprint_fragment(module(), Ecto.UUID.t()) :: %{
          users: [Ecto.UUID.t()],
          sessions: [Ecto.UUID.t()],
          devices: [Ecto.UUID.t()]
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
