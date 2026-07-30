defmodule CommsCore.Conversations.Bootstrap do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo

  alias CommsCore.Accounts.{
    InitialConversationCommand,
    InitialConversationReceipt
  }

  alias CommsCore.Conversations.{Conversation, Membership}

  def create_initial_channel(%InitialConversationCommand{} = command) do
    if Repo.in_transaction?() do
      with {:ok, conversation} <- persist_initial_tenant_channel(Repo, command) do
        {:ok, initial_conversation_receipt(conversation, command.owner_user_id)}
      end
    else
      {:error, :transaction_required}
    end
  end

  def fetch_initial_channel(tenant_id, owner_user_id)
      when is_binary(tenant_id) and is_binary(owner_user_id) do
    if Repo.in_transaction?() do
      candidates =
        Repo.all(
          from(conversation in Conversation,
            left_join: membership in Membership,
            on:
              membership.tenant_id == conversation.tenant_id and
                membership.conversation_id == conversation.id and
                membership.user_id == ^owner_user_id,
            where:
              conversation.tenant_id == ^tenant_id and
                conversation.created_by_user_id == ^owner_user_id and
                conversation.kind == :channel and conversation.title == "General",
            order_by: [asc: conversation.inserted_at],
            select: {conversation, membership}
          )
        )

      case candidates do
        [
          {%Conversation{archived_at: nil} = conversation,
           %Membership{role: :owner, left_at: nil}}
        ] ->
          {:ok, initial_conversation_receipt(conversation, owner_user_id)}

        _ ->
          {:ok, nil}
      end
    else
      {:error, :transaction_required}
    end
  end

  def fetch_initial_channel(_tenant_id, _owner_user_id),
    do: {:error, :initial_conversation_not_found}

  defp persist_initial_tenant_channel(repo, %InitialConversationCommand{} = command) do
    with {:ok, conversation} <-
           %Conversation{id: command.id}
           |> Conversation.changeset(%{
             tenant_id: command.tenant_id,
             created_by_user_id: command.owner_user_id,
             kind: :channel,
             title: "General",
             visibility: :tenant,
             next_sequence: 1
           })
           |> repo.insert(),
         {:ok, _membership} <-
           %Membership{}
           |> Membership.changeset(%{
             tenant_id: command.tenant_id,
             conversation_id: conversation.id,
             user_id: command.owner_user_id,
             role: :owner,
             joined_at: command.joined_at,
             last_read_sequence: 0
           })
           |> repo.insert() do
      {:ok, conversation}
    end
  end

  defp initial_conversation_receipt(%Conversation{} = conversation, owner_user_id) do
    %InitialConversationReceipt{
      id: conversation.id,
      tenant_id: conversation.tenant_id,
      owner_user_id: owner_user_id,
      kind: conversation.kind,
      title: conversation.title,
      visibility: conversation.visibility,
      latest_sequence: max(conversation.next_sequence - 1, 0),
      archived_at: conversation.archived_at,
      version: conversation.lock_version,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end
end
