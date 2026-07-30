defmodule CommsCore.Conversations.DirectConversations do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, AdmissionQuotas, Repo}
  alias CommsCore.Conversations.{Commands, Conversation, Directory, Membership}

  def get_or_create_view(other_user_id, subject)
      when is_binary(other_user_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, other_user_id} <- Ecto.UUID.cast(other_user_id),
         false <- grant.user_id == other_user_id do
      Repo.transaction(fn ->
        policy = Commands.admission_policy!(grant.tenant_id)
        locked_grant = lock_direct_access!(subject, grant)
        member_ids = Enum.sort([locked_grant.user_id, other_user_id])

        lock_directory_members!(locked_grant.tenant_id, member_ids)

        direct_key = direct_key(member_ids)

        case lock_direct_conversation(locked_grant.tenant_id, direct_key) do
          %Conversation{archived_at: nil} = conversation ->
            ensure_active_direct_memberships!(conversation, member_ids)

            %{conversation: conversation, created: false}

          %Conversation{} ->
            Repo.rollback(:direct_conversation_unavailable)

          nil ->
            Commands.quota_ok!(
              AdmissionQuotas.check_conversation_creation(
                policy,
                Commands.active_conversation_count(locked_grant.tenant_id),
                2
              )
            )

            conversation =
              create_direct_conversation!(
                locked_grant.tenant_id,
                locked_grant.user_id,
                member_ids,
                direct_key,
                subject
              )

            %{conversation: conversation, created: true}
        end
      end)
      |> Commands.transaction_result()
      |> project_result(subject)
    else
      {:error, _reason} -> {:error, :forbidden}
      true -> {:error, :not_found}
      :error -> {:error, :not_found}
    end
  end

  def get_or_create_view(_other_user_id, _subject), do: {:error, :not_found}

  defp direct_key(member_ids), do: member_ids |> Enum.sort() |> Enum.join(":")

  defp lock_direct_access!(subject, expected_grant) do
    case Accounts.lock_access_grant(subject) do
      {:ok, locked_grant}
      when locked_grant.tenant_id == expected_grant.tenant_id and
             locked_grant.user_id == expected_grant.user_id ->
        locked_grant

      _ ->
        Repo.rollback(:forbidden)
    end
  end

  defp lock_directory_members!(tenant_id, member_ids) do
    case Accounts.lock_active_human_directory_users(tenant_id, member_ids) do
      {:ok, people} when length(people) == 2 -> :ok
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_direct_conversation(tenant_id, direct_key) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.tenant_id == ^tenant_id and conversation.kind == :direct and
            conversation.direct_key == ^direct_key,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_active_direct_memberships!(conversation, member_ids) do
    active_member_ids =
      Repo.all(
        from(membership in Membership,
          where:
            membership.tenant_id == ^conversation.tenant_id and
              membership.conversation_id == ^conversation.id and
              membership.user_id in ^member_ids and is_nil(membership.left_at),
          order_by: [asc: membership.user_id],
          select: membership.user_id,
          lock: "FOR SHARE"
        )
      )

    if active_member_ids != member_ids, do: Repo.rollback(:direct_conversation_unavailable)
  end

  defp create_direct_conversation!(
         tenant_id,
         actor_user_id,
         member_ids,
         direct_key,
         subject
       ) do
    timestamp = Commands.now()

    conversation =
      %Conversation{}
      |> Conversation.changeset(%{
        tenant_id: tenant_id,
        created_by_user_id: actor_user_id,
        kind: :direct,
        visibility: :private,
        direct_key: direct_key,
        next_sequence: 1
      })
      |> insert_or_rollback()

    Enum.each(member_ids, fn member_id ->
      role = if member_id == actor_user_id, do: :owner, else: :member

      %Membership{}
      |> Membership.changeset(%{
        tenant_id: tenant_id,
        conversation_id: conversation.id,
        user_id: member_id,
        role: role,
        joined_at: timestamp,
        last_read_sequence: 0
      })
      |> insert_or_rollback()
    end)

    Commands.insert_event(conversation, "conversation.created.v1", subject, %{
      kind: :direct,
      title: nil,
      member_ids: member_ids
    })

    conversation
  end

  defp project_result({:ok, result}, subject) do
    {:ok,
     %{
       result
       | conversation: Directory.project_authorized_conversation(result.conversation, subject)
     }}
  end

  defp project_result({:error, _reason} = error, _subject), do: error

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
