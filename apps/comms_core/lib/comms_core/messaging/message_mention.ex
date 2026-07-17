defmodule CommsCore.Messaging.MessageMention do
  use CommsCore.Schema

  schema "message_mentions" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    field(:message_id, :binary_id)
    belongs_to(:user, CommsCore.Accounts.User)
    timestamps(updated_at: false)
  end

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, [:tenant_id, :message_id, :user_id])
    |> validate_required([:tenant_id, :message_id, :user_id])
    |> unique_constraint([:message_id, :user_id])
    |> foreign_key_constraint(:message_id, name: :message_mentions_tenant_message_fk)
    |> foreign_key_constraint(:user_id, name: :message_mentions_tenant_user_fk)
  end
end
