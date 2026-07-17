defmodule CommsCore.Messaging.Message do
  use CommsCore.Schema

  schema "messages" do
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:sender_user_id, Ecto.UUID)
    field(:sender_device_id, Ecto.UUID)
    belongs_to(:reply_to_message, __MODULE__)
    belongs_to(:thread_root_message, __MODULE__)
    field(:client_message_id, :string)
    field(:conversation_sequence, :integer)
    field(:body, :string)
    field(:metadata, :map, default: %{})
    field(:status, Ecto.Enum, values: [:active, :deleted, :moderated], default: :active)
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    has_many(:attachments, CommsCore.Attachments.Attachment)
    has_many(:reactions, CommsCore.Messaging.Reaction)
    has_many(:mentions, CommsCore.Messaging.MessageMention)
    field(:thread_reply_count, :integer, virtual: true, default: 0)
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
      :thread_root_message_id,
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
