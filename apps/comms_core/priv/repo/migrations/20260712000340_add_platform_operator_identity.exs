defmodule CommsCore.Repo.Migrations.AddPlatformOperatorIdentity do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :platform_role, :text
    end

    create constraint(:users, :users_platform_role_allowed,
             check:
               "platform_role IS NULL OR platform_role IN ('platform_operator', 'support_operator', 'security_operator')"
           )
  end

  def down do
    drop constraint(:users, :users_platform_role_allowed)

    alter table(:users) do
      remove :platform_role
    end
  end
end
