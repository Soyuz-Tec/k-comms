defmodule CommsCore.Repo.Migrations.EnforceTenantRelationships do
  use Ecto.Migration

  @constraints [
    {:devices, :devices_tenant_user_fk, [:tenant_id, :user_id], :users},
    {:sessions, :sessions_tenant_user_fk, [:tenant_id, :user_id], :users},
    {:sessions, :sessions_tenant_device_fk, [:tenant_id, :device_id], :devices},
    {:conversation_memberships, :memberships_tenant_conversation_fk,
     [:tenant_id, :conversation_id], :conversations},
    {:conversation_memberships, :memberships_tenant_user_fk, [:tenant_id, :user_id], :users},
    {:messages, :messages_tenant_conversation_fk, [:tenant_id, :conversation_id], :conversations},
    {:messages, :messages_tenant_sender_user_fk, [:tenant_id, :sender_user_id], :users},
    {:messages, :messages_tenant_sender_device_fk, [:tenant_id, :sender_device_id], :devices},
    {:message_revisions, :message_revisions_tenant_message_fk, [:tenant_id, :message_id], :messages},
    {:message_revisions, :message_revisions_tenant_editor_fk, [:tenant_id, :editor_user_id], :users},
    {:message_reactions, :message_reactions_tenant_message_fk, [:tenant_id, :message_id], :messages},
    {:message_reactions, :message_reactions_tenant_user_fk, [:tenant_id, :user_id], :users},
    {:attachments, :attachments_tenant_owner_fk, [:tenant_id, :owner_user_id], :users},
    {:attachments, :attachments_tenant_message_fk, [:tenant_id, :message_id], :messages}
  ]

  def up do
    for table <- [:users, :devices, :conversations, :messages] do
      create unique_index(table, [:tenant_id, :id], name: composite_index(table))
    end

    for {table, name, columns, target} <- @constraints do
      execute(add_constraint(table, name, columns, target))
    end
  end

  def down do
    for {table, name, _columns, _target} <- Enum.reverse(@constraints) do
      execute("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{name}")
    end

    for table <- [:messages, :conversations, :devices, :users] do
      drop_if_exists index(table, [:tenant_id, :id], name: composite_index(table))
    end
  end

  defp add_constraint(table, name, columns, target) do
    columns = Enum.join(columns, ", ")

    "ALTER TABLE #{table} ADD CONSTRAINT #{name} " <>
      "FOREIGN KEY (#{columns}) REFERENCES #{target} (tenant_id, id)"
  end

  defp composite_index(table), do: String.to_atom("#{table}_tenant_id_id_unique")
end
