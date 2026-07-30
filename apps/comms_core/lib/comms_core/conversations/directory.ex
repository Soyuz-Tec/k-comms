defmodule CommsCore.Conversations.Directory do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo, ServiceAccounts}

  alias CommsCore.Conversations.{
    AccessPolicy,
    AvailabilityQuery,
    Conversation,
    ConversationView,
    Membership,
    Projector
  }

  def list_for_service(subject) when is_map(subject) do
    with :ok <- ServiceAccounts.authorize_service(subject, "conversations:read") do
      {:ok, list_for_user_views(subject)}
    end
  end

  def list_for_service(_subject), do: {:error, :forbidden}

  def project(%Conversation{} = conversation), do: Projector.conversation(conversation)
  def project(%ConversationView{} = conversation), do: conversation

  def list_for_user_views(subject) do
    results = list_for_user(subject)
    counterparts = direct_counterparts(results, subject)

    Enum.map(results, fn result ->
      Projector.user_conversation(
        result,
        Map.get(counterparts, result.conversation.id)
      )
    end)
  end

  def get_for_user_view(id, subject) do
    get_for_user(id, subject)
    |> project_result(&project_authorized_user_conversation(&1, subject))
  end

  def list_member_views(id, subject) do
    with {:ok, members} <- list_members(id, subject) do
      {:ok, Enum.map(members, &Projector.membership/1)}
    end
  end

  def list_for_user(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    unavailable_conversations = AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

    from(c in Conversation,
      join: m in Membership,
      on: m.conversation_id == c.id,
      where:
        c.tenant_id == ^tenant_id and m.tenant_id == ^tenant_id and m.user_id == ^user_id and
          is_nil(m.left_at) and is_nil(c.archived_at) and
          c.id not in subquery(unavailable_conversations),
      order_by: [desc: c.updated_at],
      select: %{
        conversation: c,
        membership_role: m.role,
        last_read_sequence: m.last_read_sequence,
        unread_count: fragment("GREATEST((? - 1) - ?, 0)", c.next_sequence, m.last_read_sequence)
      }
    )
    |> Repo.all()
  end

  def get_for_user(id, subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    query =
      from(c in Conversation,
        join: m in Membership,
        on: m.conversation_id == c.id,
        where:
          c.id == ^id and c.tenant_id == ^tenant_id and m.tenant_id == ^tenant_id and
            m.user_id == ^user_id and is_nil(m.left_at),
        select: %{
          conversation: c,
          membership_role: m.role,
          last_read_sequence: m.last_read_sequence,
          unread_count:
            fragment("GREATEST((? - 1) - ?, 0)", c.next_sequence, m.last_read_sequence)
        }
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      result -> {:ok, result}
    end
  end

  def list_members(conversation_id, subject) do
    with :ok <- AccessPolicy.authorize_read(conversation_id, subject) do
      tenant_id = value(subject, :tenant_id)

      memberships =
        Repo.all(
          from(membership in Membership,
            where:
              membership.conversation_id == ^conversation_id and
                membership.tenant_id == ^tenant_id and is_nil(membership.left_at)
          )
        )

      memberships_by_user_id = Map.new(memberships, &{&1.user_id, &1})

      members =
        tenant_id
        |> Accounts.resolve_user_views(Map.keys(memberships_by_user_id))
        |> Enum.map(fn user ->
          %{membership: Map.fetch!(memberships_by_user_id, user.id), user: user}
        end)

      {:ok, members}
    end
  end

  def active_member_ids(tenant_id, conversation_id)
      when is_binary(tenant_id) and is_binary(conversation_id) do
    Repo.all(
      from(m in Membership,
        where:
          m.tenant_id == ^tenant_id and m.conversation_id == ^conversation_id and
            is_nil(m.left_at),
        order_by: [asc: m.user_id],
        select: m.user_id
      )
    )
  end

  @doc false
  def project_authorized_conversation(%Conversation{} = conversation, subject) do
    counterparts = direct_counterparts([%{conversation: conversation}], subject)

    Projector.conversation(
      conversation,
      Map.get(counterparts, conversation.id)
    )
  end

  defp project_authorized_user_conversation(result, subject) do
    counterparts = direct_counterparts([result], subject)

    Projector.user_conversation(
      result,
      Map.get(counterparts, result.conversation.id)
    )
  end

  defp direct_counterparts(results, subject) do
    case Accounts.access_grant(subject) do
      {:ok, grant} -> direct_counterparts_for_grant(results, grant)
      _ -> %{}
    end
  end

  defp direct_counterparts_for_grant(results, grant) do
    tenant_id = grant.tenant_id
    user_id = grant.user_id

    direct_ids =
      results
      |> Enum.flat_map(fn
        %{conversation: %Conversation{tenant_id: ^tenant_id, kind: :direct, id: id}} -> [id]
        _ -> []
      end)
      |> Enum.uniq()

    counterpart_memberships =
      if direct_ids == [] do
        []
      else
        Repo.all(
          from(membership in Membership,
            where:
              membership.tenant_id == ^tenant_id and
                membership.conversation_id in ^direct_ids and membership.user_id != ^user_id and
                is_nil(membership.left_at),
            order_by: [asc: membership.conversation_id, asc: membership.user_id],
            select: %{
              conversation_id: membership.conversation_id,
              user_id: membership.user_id
            }
          )
        )
      end

    counterpart_users =
      tenant_id
      |> Accounts.resolve_user_views(Enum.map(counterpart_memberships, & &1.user_id))
      |> Map.new(&{&1.id, &1})

    Map.new(counterpart_memberships, fn membership ->
      counterpart =
        case Map.get(counterpart_users, membership.user_id) do
          %{id: id, display_name: display_name} ->
            %{user_id: id, display_name: display_name}

          nil ->
            nil
        end

      {membership.conversation_id, counterpart}
    end)
  end

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
