defmodule CommsCore.Messaging.Projector do
  @moduledoc false

  alias CommsCore.Attachments.Projector, as: AttachmentProjector
  alias CommsCore.Messaging.{Message, MessageMention, MessageView, Reaction, ReactionView}

  def message(%Message{} = message, thread_reply_count) do
    %MessageView{
      id: message.id,
      tenant_id: message.tenant_id,
      conversation_id: message.conversation_id,
      sender_user_id: message.sender_user_id,
      sender_device_id: message.sender_device_id,
      reply_to_message_id: message.reply_to_message_id,
      thread_root_message_id: message.thread_root_message_id,
      thread_reply_count: thread_reply_count,
      mentioned_user_ids: mention_user_ids(message.mentions),
      client_message_id: message.client_message_id,
      conversation_sequence: message.conversation_sequence,
      body: message.body,
      metadata: message.metadata || %{},
      status: message.status,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at,
      attachments: project_attachments(message.attachments),
      reactions: reactions(message.reactions)
    }
  end

  def reaction(%Reaction{} = reaction) do
    %ReactionView{
      id: reaction.id,
      message_id: reaction.message_id,
      user_id: reaction.user_id,
      emoji: reaction.emoji
    }
  end

  defp project_attachments(%Ecto.Association.NotLoaded{}), do: []

  defp project_attachments(values) when is_list(values),
    do: AttachmentProjector.attachments(values)

  defp project_attachments(_), do: []

  defp reactions(%Ecto.Association.NotLoaded{}), do: []
  defp reactions(values) when is_list(values), do: Enum.map(values, &reaction/1)
  defp reactions(_), do: []

  defp mention_user_ids(%Ecto.Association.NotLoaded{}), do: []

  defp mention_user_ids(mentions) when is_list(mentions) do
    mentions
    |> Enum.map(fn %MessageMention{user_id: user_id} -> user_id end)
    |> Enum.sort()
  end

  defp mention_user_ids(_), do: []
end
