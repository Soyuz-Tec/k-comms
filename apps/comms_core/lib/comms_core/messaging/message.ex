defmodule CommsCore.Messaging.Message do
  use CommsCore.Schema

  schema "messages" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    belongs_to(:sender_user, CommsCore.Accounts.User)
    belongs_to(:sender_device, CommsCore.Accounts.Device)
    belongs_to(:reply_to_message, __MODULE__)
    field(:client_message_id, :string)
    field(:conversation_sequence, :integer)
    field(:body, :string)
    field(:metadata, :map, default: %{})
    field(:status, Ecto.Enum, values: [:active, :deleted, :moderated], default: :active)
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    has_many(:attachments, CommsCore.Attachments.Attachment)
    has_many(:reactions, CommsCore.Messaging.Reaction)
    timestamps(updated_at: false)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :sender_user_id,
      :sender_device_id,
      :reply_to_message_id,
      :client_message_id,
      :conversation_sequence,
      :body,
      :metadata,
      :status,
      :edited_at,
      :deleted_at
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :sender_user_id,
      :sender_device_id,
      :client_message_id,
      :conversation_sequence,
      :status
    ])
    |> validate_content()
    |> validate_length(:client_message_id, min: 8, max: 128)
    |> validate_length(:body, max: 65_535)
    |> unique_constraint([:conversation_id, :conversation_sequence])
    |> unique_constraint([:tenant_id, :sender_device_id, :client_message_id])
  end

  def edit_changeset(value, attrs) do
    value
    |> cast(attrs, [:body, :edited_at])
    |> validate_required([:body, :edited_at])
    |> validate_length(:body, min: 1, max: 65_535)
  end

  def delete_changeset(value, attrs) do
    value
    |> cast(attrs, [:body, :status, :deleted_at])
    |> validate_required([:status, :deleted_at])
  end

  defp validate_content(changeset) do
    status = get_field(changeset, :status)
    body = get_field(changeset, :body)

    if status == :active and (not is_binary(body) or String.trim(body) == "") do
      add_error(changeset, :body, "must be present for an active message")
    else
      changeset
    end
  end
end
