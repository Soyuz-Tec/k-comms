defmodule CommsCore.Messaging.Reaction do
  use CommsCore.Schema

  schema "message_reactions" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    field(:message_id, :binary_id)
    belongs_to(:user, CommsCore.Accounts.User)
    field(:emoji, :string)
    timestamps(updated_at: false)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:tenant_id, :message_id, :user_id, :emoji])
    |> validate_required([:tenant_id, :message_id, :user_id, :emoji])
    |> validate_length(:emoji, min: 1, max: 32)
    |> unique_constraint([:message_id, :user_id, :emoji])
  end
end
