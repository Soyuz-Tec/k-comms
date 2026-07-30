defmodule CommsCore.Conversations.DataLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo
  alias CommsCore.Conversations.{Conversation, Membership}

  def archive_for_erasure(tenant_id, conversation_id, %DateTime{} = timestamp)
      when is_binary(tenant_id) and is_binary(conversation_id) do
    if Repo.in_transaction?() do
      {count, _} =
        Repo.update_all(
          from(conversation in Conversation,
            where: conversation.id == ^conversation_id and conversation.tenant_id == ^tenant_id
          ),
          set: [archived_at: timestamp, updated_at: timestamp]
        )

      {:ok, count}
    else
      {:error, :transaction_required}
    end
  end

  def archive_for_erasure(_tenant_id, _conversation_id, _timestamp),
    do: {:error, :invalid_erasure_scope}

  def remove_user_memberships_for_erasure(tenant_id, user_id, %DateTime{} = timestamp)
      when is_binary(tenant_id) and is_binary(user_id) do
    if Repo.in_transaction?() do
      {count, _} =
        Repo.update_all(
          from(membership in Membership,
            where:
              membership.tenant_id == ^tenant_id and membership.user_id == ^user_id and
                is_nil(membership.left_at)
          ),
          set: [left_at: timestamp, updated_at: timestamp]
        )

      {:ok, count}
    else
      {:error, :transaction_required}
    end
  end

  def remove_user_memberships_for_erasure(_tenant_id, _user_id, _timestamp),
    do: {:error, :invalid_erasure_scope}

  def validate_reference(tenant_id, conversation_id) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         true <-
           Repo.exists?(
             from(conversation in Conversation,
               where: conversation.tenant_id == ^tenant_id and conversation.id == ^conversation_id
             )
           ) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  def retention_scope_ids(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, tenant_id} ->
        Repo.all(
          from(conversation in Conversation,
            where: conversation.tenant_id == ^tenant_id,
            order_by: [asc: conversation.id],
            select: conversation.id
          )
        )

      :error ->
        []
    end
  end
end
