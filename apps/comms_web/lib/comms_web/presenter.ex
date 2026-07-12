defmodule CommsWeb.Presenter do
  alias CommsCore.Accounts.{Device, Tenant, User}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Messaging.{Message, Reaction}

  def tenant(%Tenant{} = tenant) do
    %{id: tenant.id, name: tenant.name, slug: tenant.slug, status: tenant.status}
  end

  def user(%User{} = user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: user.email,
      role: user.role,
      status: user.status
    }
  end

  def device(%Device{} = device) do
    %{
      id: device.id,
      user_id: device.user_id,
      name: device.name,
      platform: device.platform,
      last_seen_at: device.last_seen_at
    }
  end

  def conversation(%{conversation: %Conversation{} = conversation} = result) do
    conversation(conversation)
    |> Map.merge(%{
      membership_role: result.membership_role,
      last_read_sequence: result.last_read_sequence,
      unread_count: result.unread_count
    })
  end

  def conversation(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      kind: conversation.kind,
      title: conversation.title,
      visibility: conversation.visibility,
      latest_sequence: max(conversation.next_sequence - 1, 0),
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  def membership(%{membership: %Membership{} = membership, user: %User{} = user}) do
    %{
      id: membership.id,
      role: membership.role,
      joined_at: membership.joined_at,
      last_read_sequence: membership.last_read_sequence,
      user: user(user)
    }
  end

  def message(%Message{} = message) do
    %{
      id: message.id,
      tenant_id: message.tenant_id,
      conversation_id: message.conversation_id,
      sender_user_id: message.sender_user_id,
      sender_device_id: message.sender_device_id,
      reply_to_message_id: message.reply_to_message_id,
      client_message_id: message.client_message_id,
      conversation_sequence: message.conversation_sequence,
      body: message.body,
      metadata: message.metadata || %{},
      status: message.status,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at,
      attachments: association(message.attachments, &attachment/1),
      reactions: association(message.reactions, &reaction/1)
    }
  end

  def attachment(%Attachment{} = attachment) do
    %{
      id: attachment.id,
      message_id: attachment.message_id,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      checksum_sha256: attachment.checksum_sha256,
      status: attachment.status,
      uploaded_at: attachment.uploaded_at
    }
  end

  defp reaction(%Reaction{} = reaction) do
    %{id: reaction.id, user_id: reaction.user_id, emoji: reaction.emoji}
  end

  defp association(%Ecto.Association.NotLoaded{}, _mapper), do: []
  defp association(values, mapper) when is_list(values), do: Enum.map(values, mapper)
  defp association(_, _mapper), do: []
end
