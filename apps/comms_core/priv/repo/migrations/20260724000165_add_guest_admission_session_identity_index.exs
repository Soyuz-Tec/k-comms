defmodule CommsCore.Repo.Migrations.AddGuestAdmissionSessionIdentityIndex do
  use Ecto.Migration

  @create_index """
  CREATE UNIQUE INDEX IF NOT EXISTS sessions_tenant_user_id_id_unique
  ON sessions (tenant_id, user_id, id)
  """

  def up do
    execute(@create_index)
  end

  def down do
    # The later guest-admission ownership constraint depends on this
    # IdentityAccess-owned key. Preserve it across a partial rollback.
    execute(@create_index)
  end
end
