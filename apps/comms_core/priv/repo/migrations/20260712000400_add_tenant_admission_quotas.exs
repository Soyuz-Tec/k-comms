defmodule CommsCore.Repo.Migrations.AddTenantAdmissionQuotas do
  use Ecto.Migration

  def up do
    alter table(:tenant_settings) do
      add(:max_active_users, :integer, null: false, default: 500)
      add(:max_active_conversations, :integer, null: false, default: 2_000)
      add(:max_conversation_members, :integer, null: false, default: 250)
    end

    create(
      constraint(:tenant_settings, :tenant_settings_max_active_users_bounded,
        check: "max_active_users BETWEEN 1 AND 1000000"
      )
    )

    create(
      constraint(:tenant_settings, :tenant_settings_max_active_conversations_bounded,
        check: "max_active_conversations BETWEEN 1 AND 10000000"
      )
    )

    create(
      constraint(:tenant_settings, :tenant_settings_max_conversation_members_bounded,
        check: "max_conversation_members BETWEEN 2 AND 100000"
      )
    )
  end

  def down do
    drop(constraint(:tenant_settings, :tenant_settings_max_conversation_members_bounded))
    drop(constraint(:tenant_settings, :tenant_settings_max_active_conversations_bounded))
    drop(constraint(:tenant_settings, :tenant_settings_max_active_users_bounded))

    alter table(:tenant_settings) do
      remove(:max_conversation_members)
      remove(:max_active_conversations)
      remove(:max_active_users)
    end
  end
end
