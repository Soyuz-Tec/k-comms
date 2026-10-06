defmodule CommsCore.Repo.Migrations.AddConversationFavorites do
  use Ecto.Migration

  def change do
    alter table(:conversation_memberships) do
      add(:favorite, :boolean, null: false, default: false)
    end
  end
end
