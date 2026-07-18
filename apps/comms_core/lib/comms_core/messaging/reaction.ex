defmodule CommsCore.Messaging.Reaction do
  use CommsCore.Schema

  schema "message_reactions" do
    field(:tenant_id, Ecto.UUID)
    field(:message_id, :binary_id)
    field(:user_id, Ecto.UUID)
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
