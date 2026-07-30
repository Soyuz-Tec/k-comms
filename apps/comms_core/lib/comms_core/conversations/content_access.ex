defmodule CommsCore.Conversations.ContentAccess do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Conversations.{Conversation, Membership, MessageWriteSlot}

  def reserve_message_slot(tenant_id, conversation_id)
      when is_binary(tenant_id) and is_binary(conversation_id) do
    if Repo.in_transaction?() do
      case Repo.one(
             from(conversation in Conversation,
               where:
                 conversation.id == ^conversation_id and conversation.tenant_id == ^tenant_id,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          {:error, :conversation_not_found}

        %Conversation{} = conversation ->
          sequence = conversation.next_sequence

          case conversation
               |> Conversation.changeset(%{next_sequence: sequence + 1})
               |> Repo.update() do
            {:ok, _conversation} ->
              {:ok,
               %MessageWriteSlot{
                 id: conversation.id,
                 tenant_id: conversation.tenant_id,
                 sequence: sequence
               }}

            {:error, _changeset} ->
              {:error, :message_slot_update_failed}
          end
      end
    else
      {:error, :transaction_required}
    end
  end

  def reserve_message_slot(_tenant_id, _conversation_id),
    do: {:error, :conversation_not_found}

  def validate_active_members(_tenant_id, _conversation_id, []), do: :ok

  def validate_active_members(tenant_id, conversation_id, user_ids)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_list(user_ids) do
    member_user_ids =
      Repo.all(
        from(membership in Membership,
          where:
            membership.tenant_id == ^tenant_id and
              membership.conversation_id == ^conversation_id and
              membership.user_id in ^user_ids and is_nil(membership.left_at),
          select: membership.user_id
        )
      )

    requested_user_ids = MapSet.new(user_ids)
    active_user_ids = Accounts.resolve_active_user_ids(tenant_id, member_user_ids)

    if MapSet.new(member_user_ids) == requested_user_ids and
         MapSet.new(active_user_ids) == requested_user_ids,
       do: :ok,
       else: {:error, :invalid_mentions}
  end

  def validate_active_members(_tenant_id, _conversation_id, _user_ids),
    do: {:error, :invalid_mentions}
end
