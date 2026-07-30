defmodule CommsCore.Conversations.AdmissionUsageQuery do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo
  alias CommsCore.Conversations.{AdmissionUsage, Conversation, GuestAdmission, Membership}

  def get(tenant_id) when is_binary(tenant_id) do
    {active_conversations, largest_conversation_members} = counts(tenant_id)

    %AdmissionUsage{
      active_conversations: active_conversations,
      largest_conversation_members: largest_conversation_members
    }
  end

  defp counts(tenant_id) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    admitted_member_counts =
      from(membership in Membership,
        left_join: guest_admission in GuestAdmission,
        on:
          guest_admission.tenant_id == membership.tenant_id and
            guest_admission.membership_id == membership.id and
            is_nil(guest_admission.converted_at),
        where:
          membership.tenant_id == ^tenant_id and is_nil(membership.left_at) and
            (is_nil(guest_admission.id) or
               (is_nil(guest_admission.revoked_at) and
                  guest_admission.expires_at > ^timestamp)),
        group_by: membership.conversation_id,
        select: %{
          conversation_id: membership.conversation_id,
          member_count: count(membership.id)
        }
      )

    active_member_counts =
      from(conversation in Conversation,
        left_join: counts in subquery(admitted_member_counts),
        on: counts.conversation_id == conversation.id,
        where: conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at),
        select: %{member_count: fragment("COALESCE(?, 0)", counts.member_count)}
      )

    from(counts in subquery(active_member_counts),
      select: {count(counts.member_count), fragment("COALESCE(MAX(?), 0)", counts.member_count)}
    )
    |> Repo.one()
  end
end
