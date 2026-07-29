defmodule CommsWeb.Presenters.Conversations do
  @moduledoc false

  alias CommsCore.Accounts.{InitialConversationReceipt, UserView}

  alias CommsCore.Conversations.{
    ConversationView,
    GuestLinkPreviewView,
    MembershipView
  }

  alias CommsWeb.Presenters.Identity

  def conversation(%ConversationView{} = conversation) do
    base = %{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      kind: conversation.kind,
      title: conversation.title,
      counterpart_user_id: conversation.counterpart_user_id,
      counterpart_display_name: conversation.counterpart_display_name,
      visibility: conversation.visibility,
      latest_sequence: conversation.latest_sequence,
      archived_at: conversation.archived_at,
      version: conversation.version,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }

    if is_nil(conversation.membership_role) do
      base
    else
      Map.merge(base, %{
        membership_role: conversation.membership_role,
        last_read_sequence: conversation.last_read_sequence,
        unread_count: conversation.unread_count
      })
    end
  end

  def conversation(%InitialConversationReceipt{} = conversation) do
    %{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      kind: conversation.kind,
      title: conversation.title,
      counterpart_user_id: nil,
      counterpart_display_name: nil,
      visibility: conversation.visibility,
      latest_sequence: conversation.latest_sequence,
      archived_at: conversation.archived_at,
      version: conversation.version,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  def public_channel(%ConversationView{} = conversation) do
    conversation(conversation)
    |> Map.merge(%{
      joined: conversation.joined,
      member_count: conversation.member_count,
      membership: membership(conversation.membership)
    })
  end

  def membership(%MembershipView{} = membership) do
    %{
      id: membership.id,
      role: membership.role,
      joined_at: membership.joined_at,
      left_at: membership.left_at,
      last_read_sequence: membership.last_read_sequence,
      version: membership.version
    }
    |> maybe_put_user(membership.user)
  end

  def membership(nil), do: nil

  def guest_membership(%MembershipView{} = membership) do
    %{
      id: membership.id,
      role: membership.role,
      joined_at: membership.joined_at,
      left_at: membership.left_at,
      last_read_sequence: membership.last_read_sequence,
      version: membership.version
    }
    |> maybe_put_guest_user(membership.user)
  end

  def guest_link(guest_link) when is_map(guest_link) do
    Map.take(guest_link, [
      :id,
      :tenant_id,
      :conversation_id,
      :created_by_user_id,
      :expires_at,
      :max_uses,
      :use_count,
      :remaining_uses,
      :conversion_enabled,
      :email_hint,
      :revoked_at,
      :status,
      :version,
      :inserted_at
    ])
  end

  def guest_admission(admission) when is_map(admission) do
    Map.take(admission, [
      :id,
      :conversation_id,
      :guest_link_id,
      :admitted_at,
      :expires_at,
      :history_from_sequence,
      :converted_at
    ])
  end

  def guest_preview(%GuestLinkPreviewView{} = preview) do
    %{
      room_title: preview.room_title,
      expires_at: preview.expires_at,
      conversion_enabled: preview.conversion_enabled,
      email_hint: preview.email_hint
    }
  end

  def instant_room(room) when is_map(room) do
    Map.take(room, [
      :id,
      :conversation_id,
      :owner_user_id,
      :owner_kind,
      :status,
      :participant_limit,
      :idle_since,
      :expires_at,
      :inserted_at,
      :updated_at
    ])
  end

  def instant_room_preview(preview) when is_map(preview) do
    Map.take(preview, [:room_title, :status, :expires_at, :participant_limit])
  end

  def guest_capabilities(capabilities) when is_map(capabilities) do
    presented = %{
      allow_audio_calls:
        Map.get(
          capabilities,
          :allow_audio_calls,
          Map.get(capabilities, "allow_audio_calls", false)
        ),
      allow_video_calls:
        Map.get(
          capabilities,
          :allow_video_calls,
          Map.get(capabilities, "allow_video_calls", false)
        ),
      conversion_enabled:
        Map.get(
          capabilities,
          :conversion_enabled,
          Map.get(capabilities, "conversion_enabled", false)
        ),
      email_hint: Map.get(capabilities, :email_hint, Map.get(capabilities, "email_hint"))
    }

    if Map.has_key?(capabilities, :self_service_conversion) or
         Map.has_key?(capabilities, "self_service_conversion") do
      Map.put(
        presented,
        :self_service_conversion,
        Map.get(
          capabilities,
          :self_service_conversion,
          Map.get(capabilities, "self_service_conversion", false)
        )
      )
    else
      presented
    end
  end

  def guest_capabilities(capabilities) when is_list(capabilities) do
    %{
      allow_audio_calls: :audio_calls in capabilities or "audio_calls" in capabilities,
      allow_video_calls: :video_calls in capabilities or "video_calls" in capabilities,
      conversion_enabled: false,
      email_hint: nil
    }
  end

  def guest_capabilities(_) do
    %{
      allow_audio_calls: false,
      allow_video_calls: false,
      conversion_enabled: false,
      email_hint: nil
    }
  end

  defp maybe_put_user(map, %UserView{} = user), do: Map.put(map, :user, Identity.user(user))
  defp maybe_put_user(map, _), do: map

  defp maybe_put_guest_user(map, %UserView{} = user) do
    Map.put(map, :user, %{
      id: user.id,
      display_name: user.display_name,
      account_type: user.account_type,
      role: user.role,
      status: user.status
    })
  end

  defp maybe_put_guest_user(map, _), do: map
end
