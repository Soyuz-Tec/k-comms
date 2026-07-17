defmodule CommsCore.Messaging.MessageRevision do
  use CommsCore.Schema

  schema "message_revisions" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:message, CommsCore.Messaging.Message)
    field(:editor_user_id, Ecto.UUID)
    field(:body, :string)
    field(:revision, :integer)
    timestamps(updated_at: false)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:tenant_id, :message_id, :editor_user_id, :body, :revision])
    |> validate_required([:tenant_id, :message_id, :editor_user_id, :body, :revision])
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint([:message_id, :revision])
  end
end
