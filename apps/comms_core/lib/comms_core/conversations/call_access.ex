defmodule CommsCore.Conversations.CallAccess do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo

  alias CommsCore.Conversations.{
    AvailabilityQuery,
    CallConversation,
    CallMembership,
    Conversation,
    Membership
  }

  def call_membership(tenant_id, conversation_id, user_id)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_binary(user_id) do
    unavailable_conversations =
      AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

    case Repo.one(
           from(membership in Membership,
             join: conversation in Conversation,
             on:
               conversation.id == membership.conversation_id and
                 conversation.tenant_id == membership.tenant_id,
             where:
               membership.tenant_id == ^tenant_id and
                 membership.conversation_id == ^conversation_id and
                 membership.user_id == ^user_id and is_nil(membership.left_at) and
                 conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at) and
                 conversation.id not in subquery(unavailable_conversations),
             select: %{
               tenant_id: membership.tenant_id,
               conversation_id: membership.conversation_id,
               user_id: membership.user_id,
               role: membership.role
             }
           )
         ) do
      nil -> {:error, :forbidden}
      membership -> {:ok, struct!(CallMembership, membership)}
    end
  end

  def call_membership(_tenant_id, _conversation_id, _user_id),
    do: {:error, :forbidden}

  def lock_call_conversation(tenant_id, conversation_id, lock_mode)
      when is_binary(tenant_id) and is_binary(conversation_id) and lock_mode in [:share, :update] do
    if Repo.in_transaction?() do
      unavailable_conversations =
        AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

      query =
        from(conversation in Conversation,
          where:
            conversation.id == ^conversation_id and conversation.tenant_id == ^tenant_id and
              is_nil(conversation.archived_at) and
              conversation.id not in subquery(unavailable_conversations),
          select: %{id: conversation.id, tenant_id: conversation.tenant_id}
        )

      conversation =
        case lock_mode do
          :share -> query |> lock("FOR SHARE") |> Repo.one()
          :update -> query |> lock("FOR UPDATE") |> Repo.one()
        end

      case conversation do
        nil -> {:error, :forbidden}
        projection -> {:ok, struct!(CallConversation, projection)}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock_call_conversation(_tenant_id, _conversation_id, _lock_mode),
    do: {:error, :forbidden}

  def lock_call_membership(tenant_id, conversation_id, user_id)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_binary(user_id) do
    if Repo.in_transaction?() do
      unavailable_conversations =
        AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

      case Repo.one(
             from(membership in Membership,
               where:
                 membership.tenant_id == ^tenant_id and
                   membership.conversation_id == ^conversation_id and
                   membership.user_id == ^user_id and is_nil(membership.left_at) and
                   membership.conversation_id not in subquery(unavailable_conversations),
               select: %{
                 tenant_id: membership.tenant_id,
                 conversation_id: membership.conversation_id,
                 user_id: membership.user_id,
                 role: membership.role
               },
               lock: "FOR SHARE"
             )
           ) do
        nil -> {:error, :forbidden}
        membership -> {:ok, struct!(CallMembership, membership)}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock_call_membership(_tenant_id, _conversation_id, _user_id),
    do: {:error, :forbidden}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
