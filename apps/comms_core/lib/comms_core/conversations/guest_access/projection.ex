defmodule CommsCore.Conversations.GuestAccess.Projection do
  @moduledoc false

  alias CommsCore.Conversations.{
    Conversation,
    GuestAdmissionView,
    GuestLinkPreviewView,
    GuestLinkView
  }

  alias CommsCore.Conversations.GuestAccess.Token

  def link(link, timestamp) do
    %GuestLinkView{
      id: link.id,
      tenant_id: link.tenant_id,
      conversation_id: link.conversation_id,
      created_by_user_id: link.created_by_user_id,
      expires_at: link.expires_at,
      max_uses: link.max_uses,
      use_count: link.use_count,
      remaining_uses: max(link.max_uses - link.use_count, 0),
      status: link_status(link, timestamp),
      conversion_enabled: not is_nil(link.conversion_email),
      email_hint: Token.email_hint(link.conversion_email),
      revoked_at: link.revoked_at,
      version: link.lock_version,
      inserted_at: link.inserted_at
    }
  end

  def admission(admission) do
    %GuestAdmissionView{
      id: admission.id,
      conversation_id: admission.conversation_id,
      guest_link_id: admission.guest_link_id,
      guest_user_id: admission.guest_user_id,
      membership_id: admission.membership_id,
      session_id: admission.session_id,
      admitted_at: admission.admitted_at,
      expires_at: admission.expires_at,
      revoked_at: admission.revoked_at,
      converted_at: admission.converted_at,
      history_from_sequence: admission.history_from_sequence
    }
  end

  def preview(conversation, link) do
    %GuestLinkPreviewView{
      room_title: room_title(conversation),
      expires_at: link.expires_at,
      conversion_enabled: not is_nil(link.conversion_email),
      email_hint: Token.email_hint(link.conversion_email)
    }
  end

  def room_title(%Conversation{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> "K-Comms room"
      trimmed -> trimmed
    end
  end

  def room_title(%Conversation{}), do: "K-Comms room"

  defp link_status(%{revoked_at: revoked_at}, _timestamp) when not is_nil(revoked_at),
    do: :revoked

  defp link_status(link, timestamp) do
    cond do
      DateTime.compare(link.expires_at, timestamp) != :gt -> :expired
      link.use_count >= link.max_uses -> :exhausted
      true -> :active
    end
  end
end
