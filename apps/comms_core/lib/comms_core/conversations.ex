defmodule CommsCore.Conversations do
  import Ecto.Query

  alias CommsCore.{Authorization, Outbox, Repo}
  alias CommsCore.Accounts.User
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.{Conversation, Membership}

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    kind = enum_value(value(attrs, :kind), [:direct, :group, :channel], :group)
    member_ids = normalize_member_ids(value(attrs, :member_ids), user_id)

    with :ok <- validate_members(tenant_id, member_ids),
         {:ok, direct_key} <- direct_key(kind, member_ids) do
      now = now()

      Repo.transaction(fn ->
        conversation =
          %Conversation{}
          |> Conversation.changeset(%{
            tenant_id: tenant_id,
            created_by_user_id: user_id,
            kind: kind,
            title: value(attrs, :title),
            visibility: enum_value(value(attrs, :visibility), [:private, :tenant], :private),
            direct_key: direct_key,
            next_sequence: 1
          })
          |> Repo.insert!()

        Enum.each(member_ids, fn member_id ->
          role = if member_id == user_id, do: :owner, else: :member

          %Membership{}
          |> Membership.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation.id,
            user_id: member_id,
            role: role,
            joined_at: now,
            last_read_sequence: 0
          })
          |> Repo.insert!()
        end)

        insert_event(conversation, "conversation.created.v1", subject, %{
          kind: kind,
          title: conversation.title,
          member_ids: member_ids
        })

        conversation
      end)
    end
  rescue
    error in Ecto.ConstraintError -> {:error, constraint_reason(error)}
  end

  def list_for_user(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    from(c in Conversation,
      join: m in Membership,
      on: m.conversation_id == c.id,
      where:
        c.tenant_id == ^tenant_id and m.tenant_id == ^tenant_id and m.user_id == ^user_id and
          is_nil(m.left_at),
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
    with :ok <- Authorization.authorize(:read_conversation, subject, %{id: conversation_id}) do
      query =
        from(m in Membership,
          join: u in User,
          on: u.id == m.user_id,
          where:
            m.conversation_id == ^conversation_id and
              m.tenant_id == ^value(subject, :tenant_id) and is_nil(m.left_at),
          order_by: [asc: u.display_name],
          select: %{membership: m, user: u}
        )

      {:ok, Repo.all(query)}
    end
  end

  def add_member(conversation_id, user_id, role, subject) do
    with :ok <- Authorization.authorize(:manage_conversation, subject, %{id: conversation_id}),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: value(subject, :tenant_id)
           ),
         %User{status: :active} <-
           Repo.get_by(User, id: user_id, tenant_id: value(subject, :tenant_id)) do
      now = now()

      Repo.transaction(fn ->
        assigned_role = enum_value(role, [:member, :moderator, :owner], :member)

        membership =
          case Repo.get_by(Membership, conversation_id: conversation_id, user_id: user_id) do
            nil ->
              %Membership{}
              |> Membership.changeset(%{
                tenant_id: conversation.tenant_id,
                conversation_id: conversation_id,
                user_id: user_id,
                role: assigned_role,
                joined_at: now,
                left_at: nil,
                last_read_sequence: 0
              })
              |> Repo.insert!()

            membership ->
              membership
              |> Membership.changeset(%{
                role: assigned_role,
                joined_at: now,
                left_at: nil
              })
              |> Repo.update!()
          end

        insert_event(conversation, "membership.changed.v1", subject, %{
          user_id: user_id,
          action: "added",
          role: assigned_role
        })

        membership
      end)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_member}
    end
  end

  def remove_member(conversation_id, user_id, subject) do
    with :ok <- Authorization.authorize(:manage_conversation, subject, %{id: conversation_id}),
         %Membership{} = membership <-
           Repo.get_by(Membership,
             conversation_id: conversation_id,
             user_id: user_id,
             tenant_id: value(subject, :tenant_id)
           ),
         false <- membership.role == :owner,
         %Conversation{} = conversation <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: value(subject, :tenant_id)
           ) do
      Repo.transaction(fn ->
        updated = membership |> Membership.changeset(%{left_at: now()}) |> Repo.update!()

        insert_event(conversation, "membership.changed.v1", subject, %{
          user_id: user_id,
          action: "removed",
          role: membership.role
        })

        updated
      end)
    else
      true -> {:error, :cannot_remove_owner}
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def mark_read(conversation_id, sequence, subject) when is_integer(sequence) do
    with :ok <- Authorization.authorize(:mark_read, subject, %{id: conversation_id}),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: value(subject, :tenant_id)
           ) do
      target = sequence |> max(0) |> min(max(conversation.next_sequence - 1, 0))
      now = now()

      query =
        from(m in Membership,
          where:
            m.conversation_id == ^conversation_id and
              m.user_id == ^value(subject, :user_id) and
              m.tenant_id == ^value(subject, :tenant_id) and is_nil(m.left_at)
        )

      update_query =
        from(m in query,
          update: [
            set: [
              last_read_sequence: fragment("GREATEST(?, ?)", m.last_read_sequence, ^target),
              updated_at: ^now
            ]
          ]
        )

      case Repo.update_all(update_query, []) do
        {1, _} -> {:ok, target}
        _ -> {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def mark_read(_, _, _), do: {:error, :invalid_sequence}

  defp insert_event(conversation, type, subject, payload) do
    now = now()

    Outbox.insert_and_enqueue!(%{
      tenant_id: conversation.tenant_id,
      event_type: type,
      aggregate_type: "conversation",
      aggregate_id: conversation.id,
      payload: Map.put(payload, :conversation_id, conversation.id),
      available_at: now
    })

    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: conversation.tenant_id,
      actor_user_id: value(subject, :user_id),
      action: String.replace(type, ".v1", ""),
      resource_type: "conversation",
      resource_id: conversation.id,
      metadata: payload,
      request_id: value(subject, :request_id)
    })
    |> Repo.insert!()
  end

  defp validate_members(tenant_id, member_ids) do
    count =
      User
      |> where([u], u.tenant_id == ^tenant_id and u.id in ^member_ids and u.status == :active)
      |> Repo.aggregate(:count)

    if count == length(member_ids), do: :ok, else: {:error, :invalid_members}
  end

  defp direct_key(:direct, member_ids) when length(member_ids) == 2 do
    {:ok, member_ids |> Enum.sort() |> Enum.join(":")}
  end

  defp direct_key(:direct, _), do: {:error, :direct_conversation_requires_two_members}
  defp direct_key(_, _), do: {:ok, nil}

  defp normalize_member_ids(ids, owner_id) do
    ids = if is_list(ids), do: ids, else: []
    [owner_id | ids] |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  defp enum_value(value, allowed, default) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: atom, else: default
  rescue
    ArgumentError -> default
  end

  defp enum_value(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp enum_value(_, _, default), do: default

  defp constraint_reason(%Ecto.ConstraintError{constraint: constraint}) do
    if String.contains?(constraint, "direct_key"),
      do: :direct_conversation_exists,
      else: :conflict
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
