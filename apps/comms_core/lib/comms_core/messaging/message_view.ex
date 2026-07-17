defmodule CommsCore.Messaging.MessageView do
  @moduledoc "Persistence-neutral message projection returned by the content boundary."

  @enforce_keys [
    :id,
    :tenant_id,
    :conversation_id,
    :sender_user_id,
    :sender_device_id,
    :client_message_id,
    :conversation_sequence,
    :status
  ]
  defstruct [
    :id,
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
    :deleted_at,
    :inserted_at,
    thread_reply_count: 0,
    mentioned_user_ids: [],
    attachments: [],
    reactions: []
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          sender_user_id: Ecto.UUID.t(),
          sender_device_id: Ecto.UUID.t(),
          reply_to_message_id: Ecto.UUID.t() | nil,
          thread_root_message_id: Ecto.UUID.t() | nil,
          client_message_id: String.t(),
          conversation_sequence: pos_integer(),
          body: String.t() | nil,
          metadata: map(),
          status: atom(),
          edited_at: DateTime.t() | nil,
          deleted_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          thread_reply_count: non_neg_integer(),
          mentioned_user_ids: [Ecto.UUID.t()],
          attachments: [CommsCore.Attachments.AttachmentView.t()],
          reactions: [CommsCore.Messaging.ReactionView.t()]
        }
end
