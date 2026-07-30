defmodule CommsCore.Conversations.PublicChannels do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo

  alias CommsCore.Conversations.{
    AccessPolicy,
    Commands,
    Conversation,
    Membership,
    Projector
  }

  @default_channel_limit 25
  @max_channel_limit 100

  def discover_views(params, subject) do
    with {:ok, result} <- discover(params, subject) do
      {:ok, %{result | channels: Enum.map(result.channels, &Projector.public_channel/1)}}
    end
  end

  def join_view(id, subject),
    do: join(id, subject) |> project_result(&project_membership_change/1)

  def leave_view(id, attrs, subject, revoke_call_access),
    do:
      leave(id, attrs, subject, revoke_call_access)
      |> project_result(&project_membership_change/1)

  def discover(params, subject) when is_map(params) do
    tenant_id = Commands.value(subject, :tenant_id)
    user_id = Commands.value(subject, :user_id)

    with :ok <- AccessPolicy.authorize_discovery(subject),
         {:ok, cursor} <- optional_channel_cursor(Commands.value(params, :cursor)),
         {:ok, search} <- normalize_channel_search(Commands.value(params, :q)) do
      limit = parse_channel_limit(Commands.value(params, :limit))

      active_members =
        from(m in Membership,
          where: m.tenant_id == ^tenant_id and is_nil(m.left_at),
          group_by: m.conversation_id,
          select: %{conversation_id: m.conversation_id, member_count: count(m.id)}
        )

      results =
        from(c in Conversation,
          left_join: membership in Membership,
          on:
            membership.conversation_id == c.id and membership.tenant_id == ^tenant_id and
              membership.user_id == ^user_id and is_nil(membership.left_at),
          left_join: members in subquery(active_members),
          on: members.conversation_id == c.id,
          where:
            c.tenant_id == ^tenant_id and c.kind == :channel and c.visibility == :tenant and
              is_nil(c.archived_at),
          order_by: [desc: c.inserted_at, desc: c.id],
          select: %{
            conversation: c,
            membership: membership,
            joined: not is_nil(membership.id),
            member_count: fragment("COALESCE(?, 0)", members.member_count)
          }
        )
        |> maybe_search_channels(search)
        |> maybe_before_channel_cursor(cursor)
        |> limit(^(limit + 1))
        |> Repo.all()

      has_more = length(results) > limit
      channels = Enum.take(results, limit)

      {:ok,
       %{
         channels: channels,
         limit: limit,
         has_more: has_more,
         next_cursor: if(has_more, do: channel_cursor_for(List.last(channels)), else: nil)
       }}
    end
  end

  def join(id, subject) when is_binary(id) and is_map(subject) do
    with :ok <- AccessPolicy.authorize_join(id, subject) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, subject, require_enabled: true)
        authorize_in_transaction!(fn -> AccessPolicy.authorize_join(conversation.id, subject) end)
        policy = Commands.admission_policy!(conversation.tenant_id)

        user_id = Commands.value(subject, :user_id)
        timestamp = Commands.now()

        {membership, replayed} =
          case lock_membership(conversation, user_id) do
            nil ->
              Commands.quota_ok!(
                Commands.ensure_conversation_member_capacity(policy, conversation)
              )

              membership =
                %Membership{}
                |> Membership.changeset(%{
                  tenant_id: conversation.tenant_id,
                  conversation_id: conversation.id,
                  user_id: user_id,
                  role: :member,
                  joined_at: timestamp,
                  left_at: nil,
                  last_read_sequence: 0
                })
                |> insert_or_rollback()

              {membership, false}

            %Membership{left_at: nil} = membership ->
              {membership, true}

            %Membership{} = membership ->
              Commands.quota_ok!(
                Commands.ensure_conversation_member_capacity(policy, conversation)
              )

              rejoined =
                membership
                |> Membership.changeset(%{
                  role: :member,
                  joined_at: timestamp,
                  left_at: nil
                })
                |> Ecto.Changeset.optimistic_lock(:lock_version)
                |> update_or_rollback()

              {rejoined, false}
          end

        unless replayed do
          Commands.insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: membership.user_id,
            action: "added",
            role: membership.role,
            membership_version: membership.lock_version,
            source: "self_service"
          })
        end

        %{conversation: conversation, membership: membership, replayed: replayed}
      end)
      |> Commands.transaction_result()
    end
  end

  def leave(id, attrs, subject, revoke_call_access)
      when is_binary(id) and is_map(attrs) and is_map(subject) and
             is_function(revoke_call_access, 4) do
    with :ok <- AccessPolicy.authorize_leave(id, subject),
         {:ok, expected_version} <- Commands.expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, subject, require_enabled: false)

        authorize_in_transaction!(fn ->
          AccessPolicy.authorize_leave(conversation.id, subject)
        end)

        lock_memberships!(conversation.id, conversation.tenant_id)

        membership =
          Repo.get_by(Membership,
            tenant_id: conversation.tenant_id,
            conversation_id: conversation.id,
            user_id: Commands.value(subject, :user_id)
          ) || Repo.rollback(:not_found)

        if membership.left_at do
          %{conversation: conversation, membership: membership, replayed: true}
        else
          if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)
          ensure_conversation_owner_remains!(membership)

          left_membership =
            membership
            |> Membership.changeset(%{left_at: Commands.now()})
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()

          Commands.insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: left_membership.user_id,
            action: "removed",
            role: left_membership.role,
            membership_version: left_membership.lock_version,
            source: "self_service"
          })

          revoke_call_access.(
            conversation.tenant_id,
            conversation.id,
            left_membership.user_id,
            "membership_left"
          )

          %{conversation: conversation, membership: left_membership, replayed: false}
        end
      end)
      |> Commands.transaction_result()
    end
  end

  defp normalize_channel_search(nil), do: {:ok, nil}

  defp normalize_channel_search(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      String.length(value) <= 160 -> {:ok, value}
      true -> {:error, :invalid_search_query}
    end
  end

  defp normalize_channel_search(_), do: {:error, :invalid_search_query}

  defp maybe_search_channels(query, nil), do: query

  defp maybe_search_channels(query, search) do
    where(
      query,
      [conversation, ...],
      fragment("strpos(lower(coalesce(?, '')), lower(?)) > 0", conversation.title, ^search)
    )
  end

  defp optional_channel_cursor(nil), do: {:ok, nil}
  defp optional_channel_cursor(""), do: {:ok, nil}

  defp optional_channel_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"inserted_at" => inserted_at, "id" => id}} <- Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(inserted_at),
         {:ok, _uuid} <- Ecto.UUID.cast(id) do
      {:ok, {timestamp, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_channel_cursor(_), do: {:error, :invalid_cursor}

  defp maybe_before_channel_cursor(query, nil), do: query

  defp maybe_before_channel_cursor(query, {timestamp, id}) do
    where(
      query,
      [conversation, ...],
      conversation.inserted_at < ^timestamp or
        (conversation.inserted_at == ^timestamp and conversation.id < ^id)
    )
  end

  defp channel_cursor_for(nil), do: nil

  defp channel_cursor_for(%{conversation: conversation}) do
    %{inserted_at: DateTime.to_iso8601(conversation.inserted_at), id: conversation.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp parse_channel_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_channel_limit)

  defp parse_channel_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_channel_limit(number)
      _ -> @default_channel_limit
    end
  end

  defp parse_channel_limit(_), do: @default_channel_limit

  defp lock_channel!(conversation_id, subject) do
    Repo.one(
      from(c in Conversation,
        where:
          c.id == ^conversation_id and
            c.tenant_id == ^Commands.value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_membership(conversation, user_id) do
    Repo.one(
      from(m in Membership,
        where:
          m.tenant_id == ^conversation.tenant_id and
            m.conversation_id == ^conversation.id and m.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_public_channel!(
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil},
         subject,
         require_enabled: require_enabled
       ) do
    if require_enabled do
      case AccessPolicy.validate_public_channel(subject, :channel, :tenant) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      :ok
    end
  end

  defp ensure_public_channel!(%Conversation{archived_at: archived_at}, _subject, _opts)
       when not is_nil(archived_at),
       do: Repo.rollback(:conversation_archived)

  defp ensure_public_channel!(_conversation, _subject, _opts), do: Repo.rollback(:forbidden)

  defp lock_memberships!(conversation_id, tenant_id) do
    Repo.all(
      from(m in Membership,
        where: m.conversation_id == ^conversation_id and m.tenant_id == ^tenant_id,
        select: m.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp authorize_in_transaction!(authorization) when is_function(authorization, 0) do
    case authorization.() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_conversation_owner_remains!(%Membership{role: :owner} = membership) do
    remaining =
      Membership
      |> where(
        [m],
        m.tenant_id == ^membership.tenant_id and
          m.conversation_id == ^membership.conversation_id and m.id != ^membership.id and
          m.role == :owner and is_nil(m.left_at)
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: Repo.rollback(:cannot_remove_owner)
  end

  defp ensure_conversation_owner_remains!(_), do: :ok

  defp project_membership_change(result) do
    %{
      conversation: Projector.conversation(result.conversation),
      membership: Projector.membership(result.membership),
      replayed: result.replayed
    }
  end

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
