defmodule CommsCore.Authorization.Database do
  @behaviour CommsCore.Authorization

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, Tenant, User}
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo

  @member_actions [
    :join_conversation,
    :read_conversation,
    :send_message,
    :mark_read,
    :react_message,
    :upload_attachment
  ]

  @impl true
  def authorize(action, subject, resource) when action in @member_actions do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         %Membership{} <- active_membership(subject, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:manage_conversation, subject, resource) do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         %Membership{role: role} <- active_membership(subject, conversation_id),
         true <- role in [:owner, :moderator] do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:edit_message, subject, %Message{} = message) do
    with true <- active_subject?(subject),
         true <- same_tenant?(subject, message),
         %Membership{} <- active_membership(subject, message.conversation_id),
         true <- value(subject, :user_id) == message.sender_user_id,
         true <- message.status == :active do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:delete_message, subject, %Message{} = message) do
    with true <- active_subject?(subject),
         true <- same_tenant?(subject, message),
         %Membership{} <- active_membership(subject, message.conversation_id) do
      if value(subject, :user_id) == message.sender_user_id do
        :ok
      else
        authorize(:manage_conversation, subject, %{id: message.conversation_id})
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:administer_tenant, subject, _resource) do
    with true <- active_subject?(subject),
         %User{role: role} <-
           Repo.get_by(User,
             id: value(subject, :user_id),
             tenant_id: value(subject, :tenant_id),
             status: :active
           ),
         true <- role in [:owner, :admin] do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(_, _, _), do: {:error, :forbidden}

  defp active_subject?(subject) do
    case {
      value(subject, :tenant_id),
      value(subject, :user_id),
      value(subject, :device_id),
      value(subject, :session_id)
    } do
      {tenant_id, user_id, device_id, session_id}
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) and
             is_binary(session_id) ->
        query =
          from(s in Session,
            join: t in Tenant,
            on: t.id == s.tenant_id,
            join: u in User,
            on: u.id == s.user_id,
            join: d in Device,
            on: d.id == s.device_id,
            where:
              s.id == ^session_id and s.tenant_id == ^tenant_id and s.user_id == ^user_id and
                s.device_id == ^device_id and t.id == ^tenant_id and t.status == :active and
                u.id == ^user_id and u.tenant_id == ^tenant_id and u.status == :active and
                d.id == ^device_id and d.tenant_id == ^tenant_id and d.user_id == ^user_id and
                is_nil(d.revoked_at) and is_nil(s.revoked_at) and s.expires_at > ^now(),
            select: true
          )

        Repo.exists?(query)

      _ ->
        false
    end
  end

  defp active_membership(subject, conversation_id) do
    Repo.one(
      from(m in Membership,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.conversation_id == ^conversation_id and
            m.user_id == ^value(subject, :user_id) and
            m.tenant_id == ^value(subject, :tenant_id) and
            c.tenant_id == ^value(subject, :tenant_id) and
            is_nil(m.left_at) and is_nil(c.archived_at)
      )
    )
  end

  defp conversation_id(%Conversation{id: id}), do: {:ok, id}
  defp conversation_id(%Message{conversation_id: id}), do: {:ok, id}

  defp conversation_id(resource) when is_map(resource) do
    case value(resource, :conversation_id) || value(resource, :id) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_conversation}
    end
  end

  defp conversation_id(_), do: {:error, :missing_conversation}

  defp same_tenant?(subject, resource) do
    value(subject, :tenant_id) == Map.get(resource, :tenant_id)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
