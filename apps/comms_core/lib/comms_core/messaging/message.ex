defmodule CommsCore.Messaging.Message do
  use CommsCore.Schema
  schema "messages" do
    belongs_to :tenant, CommsCore.Accounts.Tenant
    belongs_to :conversation, CommsCore.Conversations.Conversation
    belongs_to :sender_user, CommsCore.Accounts.User
    belongs_to :sender_device, CommsCore.Accounts.Device
    field :client_message_id, :string
    field :conversation_sequence, :integer
    field :body, :string
    field :status, Ecto.Enum, values: [:active, :deleted, :moderated], default: :active
    timestamps(updated_at: false)
  end
  def changeset(value, attrs) do
    value |> cast(attrs, [:tenant_id, :conversation_id, :sender_user_id, :sender_device_id, :client_message_id, :conversation_sequence, :body, :status]) |> validate_required([:tenant_id, :conversation_id, :sender_user_id, :sender_device_id, :client_message_id, :conversation_sequence, :status]) |> validate_length(:client_message_id, min: 8, max: 128) |> validate_length(:body, max: 65_535) |> unique_constraint([:conversation_id, :conversation_sequence]) |> unique_constraint([:tenant_id, :sender_device_id, :client_message_id])
  end
end
