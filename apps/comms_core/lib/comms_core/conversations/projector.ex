defmodule CommsCore.Conversations.Projector do
  @moduledoc false

  alias CommsCore.Accounts.UserView
  alias CommsCore.Conversations.{Conversation, ConversationView, Membership, MembershipView}

  def conversation(%Conversation{} = conversation) do
    struct!(ConversationView, %{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      kind: conversation.kind,
      title: conversation.title,
      visibility: conversation.visibility,
      latest_sequence: max(conversation.next_sequence - 1, 0),
      archived_at: conversation.archived_at,
      version: conversation.lock_version,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    })
  end

  def user_conversation(%{conversation: %Conversation{} = conversation} = result) do
    conversation
    |> conversation()
    |> Map.merge(%{
      membership_role: result.membership_role,
      last_read_sequence: result.last_read_sequence,
      unread_count: result.unread_count
    })
  end

  def public_channel(%{conversation: %Conversation{} = conversation} = result) do
    conversation
    |> conversation()
    |> Map.merge(%{
      joined: result.joined,
      member_count: result.member_count,
      membership: membership(Map.get(result, :membership))
    })
  end

  def membership(%{membership: %Membership{} = membership, user: %UserView{} = user}) do
    membership(membership)
    |> Map.put(:user, user)
  end

  def membership(%Membership{} = membership) do
    struct!(MembershipView, %{
      id: membership.id,
      user_id: membership.user_id,
      role: membership.role,
      joined_at: membership.joined_at,
      left_at: membership.left_at,
      last_read_sequence: membership.last_read_sequence,
      version: membership.lock_version,
      user: nil
    })
  end

  def membership(nil), do: nil
end
