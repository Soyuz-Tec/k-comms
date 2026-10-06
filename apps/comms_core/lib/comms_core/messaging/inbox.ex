defmodule CommsCore.Messaging.Inbox do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Messaging.Message
  alias CommsCore.Messaging.PersonalContent.Draft

  # Preview only the main timeline. No attachment names/URLs, encrypted data,
  # deleted/moderated bodies or a different person's drafts cross this boundary.
  def inbox_summaries(ids, subject) when is_list(ids) and length(ids) <= 500 do
    with {:ok, grant} <- Accounts.access_grant(subject) do
      if grant.account_type == :human and grant.access_scope == :workspace do
        summarize(ids, grant, subject)
      else
        # Guest admission history floors require the ordinary history endpoint.
        {:ok, %{}}
      end
    end
  end

  def inbox_summaries(_, _), do: {:error, :invalid_inbox_query}

  defp summarize(ids, grant, subject) do
    authorization = Conversations.active_membership_authorization_query(grant)

    messages =
      Repo.all(
        from(m in Message,
          join: a in subquery(authorization),
          on: a.conversation_id == m.conversation_id,
          where:
            m.tenant_id == ^grant.tenant_id and m.conversation_id in ^ids and
              is_nil(m.thread_root_message_id),
          distinct: m.conversation_id,
          order_by: [asc: m.conversation_id, desc: m.conversation_sequence],
          select: %{
            id: m.id,
            conversation_id: m.conversation_id,
            sequence: m.conversation_sequence,
            sender_user_id: m.sender_user_id,
            status: m.status,
            inserted_at: m.inserted_at,
            excerpt:
              fragment(
                "CASE WHEN ? = 'active' THEN left(coalesce(?, ''), 200) ELSE '' END",
                m.status,
                m.body
              )
          }
        )
      )

    labels =
      messages
      |> Enum.map(& &1.sender_user_id)
      |> Enum.uniq()
      |> Enum.chunk_every(200)
      |> Enum.flat_map(&Accounts.resolve_retained_sender_labels(grant.tenant_id, &1))
      |> Map.new(&{&1.id, &1.display_name})

    now = DateTime.utc_now()

    drafts =
      Repo.all(
        from(d in Draft,
          join: a in subquery(authorization),
          on: a.conversation_id == d.conversation_id,
          where:
            d.tenant_id == ^grant.tenant_id and d.user_id == ^grant.user_id and
              d.conversation_id in ^ids and d.thread_key == "main" and d.expires_at > ^now and
              d.body != "",
          select:
            {d.conversation_id,
             %{excerpt: fragment("left(?, 200)", d.body), expires_at: d.expires_at}}
        )
      )
      |> Map.new()

    messages =
      Map.new(messages, fn message ->
        {message.conversation_id,
         message
         |> Map.delete(:conversation_id)
         |> Map.put(
           :sender_display_name,
           Map.get(labels, message.sender_user_id, "Former member")
         )}
      end)

    # Recheck membership before disclosure. A summary queried before a removal
    # must not outlive a later authorization observation in the same request.
    with {:ok, %{account_type: :human, access_scope: :workspace} = current_grant} <-
           Accounts.access_grant(subject),
         true <-
           current_grant.tenant_id == grant.tenant_id and current_grant.user_id == grant.user_id do
      current_authorization = Conversations.active_membership_authorization_query(current_grant)

      authorized =
        Repo.all(
          from(a in subquery(current_authorization),
            where: a.conversation_id in ^ids,
            select: a.conversation_id
          )
        )

      {:ok,
       Map.new(authorized, &{&1, %{message: Map.get(messages, &1), draft: Map.get(drafts, &1)}})}
    else
      _ -> {:error, :forbidden}
    end
  end
end
