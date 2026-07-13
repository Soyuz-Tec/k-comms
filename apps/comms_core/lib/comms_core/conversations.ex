defmodule CommsCore.Conversations do
  import Ecto.Query

  @default_channel_limit 25
  @max_channel_limit 100

  alias CommsCore.{AdmissionQuotas, Authorization, Outbox, Repo}
  alias CommsCore.Accounts.User
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.{Conversation, Membership}

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    kind = enum_value(value(attrs, :kind), [:direct, :group, :channel], :group)
    member_ids = normalize_member_ids(value(attrs, :member_ids), user_id)

    visibility = enum_value(value(attrs, :visibility), [:private, :tenant], :private)
    visibility = if kind == :direct, do: :private, else: visibility

    with :ok <- Authorization.authorize(:create_conversation, subject, %{tenant_id: tenant_id}),
         :ok <- validate_members(tenant_id, member_ids),
         :ok <- validate_public_channel(tenant_id, kind, visibility),
         {:ok, direct_key} <- direct_key(kind, member_ids) do
      now = now()

      Repo.transaction(fn ->
        quota_ok!(AdmissionQuotas.ensure_conversation_creation(tenant_id, length(member_ids)))

        conversation =
          %Conversation{}
          |> Conversation.changeset(%{
            tenant_id: tenant_id,
            created_by_user_id: user_id,
            kind: kind,
            title: value(attrs, :title),
            visibility: visibility,
            direct_key: direct_key,
            next_sequence: 1
          })
          |> insert_or_rollback()

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
          |> insert_or_rollback()
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
          is_nil(m.left_at) and is_nil(c.archived_at),
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

  def discover_public_channels(params, subject) when is_map(params) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    with :ok <-
           Authorization.authorize(:discover_public_channels, subject, %{tenant_id: tenant_id}),
         {:ok, cursor} <- optional_channel_cursor(value(params, :cursor)),
         {:ok, search} <- normalize_channel_search(value(params, :q)) do
      limit = parse_channel_limit(value(params, :limit))

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

  def join_public_channel(id, subject) when is_binary(id) and is_map(subject) do
    with :ok <- Authorization.authorize(:join_conversation, subject, %{id: id}) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, require_enabled: true)
        authorize_in_transaction!(:join_conversation, subject, conversation)
        quota_ok!(AdmissionQuotas.lock_tenant(conversation.tenant_id))

        user_id = value(subject, :user_id)
        timestamp = now()

        {membership, replayed} =
          case lock_membership(conversation, user_id) do
            nil ->
              quota_ok!(
                AdmissionQuotas.ensure_conversation_member_capacity(
                  conversation.tenant_id,
                  conversation.id
                )
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
              quota_ok!(
                AdmissionQuotas.ensure_conversation_member_capacity(
                  conversation.tenant_id,
                  conversation.id
                )
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
          insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: membership.user_id,
            action: "added",
            role: membership.role,
            membership_version: membership.lock_version,
            source: "self_service"
          })
        end

        %{conversation: conversation, membership: membership, replayed: replayed}
      end)
      |> transaction_result()
    end
  end

  def leave_public_channel(id, attrs, subject)
      when is_binary(id) and is_map(attrs) and is_map(subject) do
    with :ok <- Authorization.authorize(:leave_conversation, subject, %{id: id}),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, require_enabled: false)
        authorize_in_transaction!(:leave_conversation, subject, conversation)
        lock_memberships!(conversation.id, conversation.tenant_id)

        membership =
          Repo.get_by(Membership,
            tenant_id: conversation.tenant_id,
            conversation_id: conversation.id,
            user_id: value(subject, :user_id)
          ) || Repo.rollback(:not_found)

        if membership.left_at do
          %{conversation: conversation, membership: membership, replayed: true}
        else
          if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)
          ensure_conversation_owner_remains!(membership)

          left_membership =
            membership
            |> Membership.changeset(%{left_at: now()})
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()

          insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: left_membership.user_id,
            action: "removed",
            role: left_membership.role,
            membership_version: left_membership.lock_version,
            source: "self_service"
          })

          %{conversation: conversation, membership: left_membership, replayed: false}
        end
      end)
      |> transaction_result()
    end
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

  def update(id, attrs, subject) when is_map(attrs) do
    with :ok <- Authorization.authorize(:manage_conversation, subject, %{id: id}),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation =
          Repo.one(
            from(c in Conversation,
              where:
                c.id == ^id and c.tenant_id == ^value(subject, :tenant_id) and
                  is_nil(c.archived_at),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if conversation.lock_version != expected_version, do: Repo.rollback(:stale_version)

        changes =
          %{}
          |> maybe_put(:title, value(attrs, :title))
          |> maybe_put(:visibility, normalized_visibility(value(attrs, :visibility)))
          |> enforce_direct_visibility(conversation)

        requested_visibility = Map.get(changes, :visibility, conversation.visibility)

        case validate_public_channel(
               conversation.tenant_id,
               conversation.kind,
               requested_visibility
             ) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        updated =
          conversation
          |> Conversation.changeset(changes)
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(updated, "conversation.updated.v1", subject, %{
          before: %{title: conversation.title, visibility: conversation.visibility},
          after: %{title: updated.title, visibility: updated.visibility},
          version: updated.lock_version
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def archive(id, attrs, subject) when is_map(attrs) do
    with :ok <- Authorization.authorize(:manage_conversation, subject, %{id: id}),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation =
          Repo.one(
            from(c in Conversation,
              where: c.id == ^id and c.tenant_id == ^value(subject, :tenant_id),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if conversation.lock_version != expected_version, do: Repo.rollback(:stale_version)
        if conversation.archived_at, do: Repo.rollback(:conversation_archived)

        archived =
          conversation
          |> Conversation.changeset(%{archived_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(archived, "conversation.archived.v1", subject, %{
          version: archived.lock_version
        })

        archived
      end)
      |> transaction_result()
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

  def active_member_ids(conversation_id) when is_binary(conversation_id) do
    Repo.all(
      from(m in Membership,
        where: m.conversation_id == ^conversation_id and is_nil(m.left_at),
        select: m.user_id
      )
    )
  end

  def add_member(conversation_id, user_id, role, subject) do
    with :ok <- Authorization.authorize(:manage_conversation, subject, %{id: conversation_id}),
         {:ok, assigned_role} <- membership_role(role) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(:manage_conversation, subject, conversation)
        quota_ok!(AdmissionQuotas.lock_tenant(conversation.tenant_id))

        Repo.get_by(User,
          id: user_id,
          tenant_id: conversation.tenant_id,
          status: :active
        ) || Repo.rollback(:invalid_member)

        timestamp = now()

        {membership, changed?} =
          case Repo.one(
                 from(m in Membership,
                   where:
                     m.conversation_id == ^conversation_id and m.user_id == ^user_id and
                       m.tenant_id == ^conversation.tenant_id,
                   lock: "FOR UPDATE"
                 )
               ) do
            nil ->
              authorize_ownership_change!(nil, assigned_role, subject, conversation)

              quota_ok!(
                AdmissionQuotas.ensure_conversation_member_capacity(
                  conversation.tenant_id,
                  conversation.id
                )
              )

              %Membership{}
              |> Membership.changeset(%{
                tenant_id: conversation.tenant_id,
                conversation_id: conversation_id,
                user_id: user_id,
                role: assigned_role,
                joined_at: timestamp,
                left_at: nil,
                last_read_sequence: 0
              })
              |> insert_or_rollback()
              |> then(&{&1, true})

            %Membership{left_at: nil} = membership ->
              authorize_ownership_change!(
                membership.role,
                assigned_role,
                subject,
                conversation
              )

              if membership.role == assigned_role do
                {membership, false}
              else
                Repo.rollback(:version_required)
              end

            membership ->
              authorize_ownership_change!(nil, assigned_role, subject, conversation)

              quota_ok!(
                AdmissionQuotas.ensure_conversation_member_capacity(
                  conversation.tenant_id,
                  conversation.id
                )
              )

              membership
              |> Membership.changeset(%{
                role: assigned_role,
                joined_at: timestamp,
                left_at: nil
              })
              |> Ecto.Changeset.optimistic_lock(:lock_version)
              |> update_or_rollback()
              |> then(&{&1, true})
          end

        if changed? do
          insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: user_id,
            action: "added",
            role: assigned_role
          })
        end

        membership
      end)
    else
      {:error, _} = error -> error
    end
  end

  def remove_member(conversation_id, user_id, attrs, subject) when is_map(attrs) do
    with :ok <- Authorization.authorize(:manage_conversation, subject, %{id: conversation_id}),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(:manage_conversation, subject, conversation)
        lock_memberships!(conversation_id, conversation.tenant_id)

        membership =
          Repo.get_by(Membership,
            conversation_id: conversation_id,
            user_id: user_id,
            tenant_id: conversation.tenant_id
          ) || Repo.rollback(:not_found)

        if membership.left_at, do: Repo.rollback(:not_found)
        authorize_ownership_change!(membership.role, nil, subject, conversation)
        if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)
        ensure_conversation_owner_remains!(membership)

        updated =
          membership
          |> Membership.changeset(%{left_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(conversation, "membership.changed.v1", subject, %{
          user_id: user_id,
          action: "removed",
          role: membership.role
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def change_member_role(conversation_id, user_id, attrs, subject) when is_map(attrs) do
    with :ok <- Authorization.authorize(:manage_conversation, subject, %{id: conversation_id}),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, role} <- membership_role(value(attrs, :role)) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(:manage_conversation, subject, conversation)

        lock_memberships!(conversation_id, conversation.tenant_id)

        membership =
          Repo.one(
            from(m in Membership,
              where:
                m.conversation_id == ^conversation_id and m.user_id == ^user_id and
                  m.tenant_id == ^conversation.tenant_id and is_nil(m.left_at)
            )
          ) || Repo.rollback(:not_found)

        authorize_ownership_change!(membership.role, role, subject, conversation)
        if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)

        if membership.role == :owner and role != :owner,
          do: ensure_conversation_owner_remains!(membership)

        updated =
          membership
          |> Membership.changeset(%{role: role})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(conversation, "membership.role_changed.v1", subject, %{
          user_id: user_id,
          before_role: membership.role,
          role: updated.role,
          version: updated.lock_version
        })

        updated
      end)
      |> transaction_result()
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
        where: c.id == ^conversation_id and c.tenant_id == ^value(subject, :tenant_id),
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
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil} = conversation,
         require_enabled: require_enabled
       ) do
    if require_enabled do
      case validate_public_channel(conversation.tenant_id, :channel, :tenant) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      :ok
    end
  end

  defp ensure_public_channel!(%Conversation{archived_at: archived_at}, _opts)
       when not is_nil(archived_at),
       do: Repo.rollback(:conversation_archived)

  defp ensure_public_channel!(_conversation, _opts), do: Repo.rollback(:forbidden)

  defp lock_memberships!(conversation_id, tenant_id) do
    Repo.all(
      from(m in Membership,
        where: m.conversation_id == ^conversation_id and m.tenant_id == ^tenant_id,
        select: m.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_conversation!(conversation_id, subject) do
    Repo.one(
      from(c in Conversation,
        where:
          c.id == ^conversation_id and c.tenant_id == ^value(subject, :tenant_id) and
            is_nil(c.archived_at),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp reject_direct_membership_change!(%Conversation{kind: :direct}),
    do: Repo.rollback(:direct_membership_immutable)

  defp reject_direct_membership_change!(_conversation), do: :ok

  defp authorize_in_transaction!(action, subject, resource) do
    case Authorization.authorize(action, subject, resource) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_ownership_change!(current_role, requested_role, subject, conversation)
       when current_role == :owner or requested_role == :owner do
    authorize_in_transaction!(:manage_conversation_ownership, subject, conversation)
  end

  defp authorize_ownership_change!(_current_role, _requested_role, _subject, _conversation),
    do: :ok

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

  defp expected_version(attrs) do
    case value(attrs, :version) || value(attrs, :lock_version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  defp membership_role(value) do
    case enum_value(value, [:member, :moderator, :owner], nil) do
      nil -> {:error, :invalid_role}
      role -> {:ok, role}
    end
  end

  defp validate_public_channel(tenant_id, :channel, :tenant) do
    case Repo.get_by(TenantSettings, tenant_id: tenant_id) do
      %TenantSettings{allow_public_channels: false} -> {:error, :public_channels_disabled}
      _ -> :ok
    end
  end

  defp validate_public_channel(_tenant_id, _kind, _visibility), do: :ok

  defp normalized_visibility(nil), do: nil

  defp normalized_visibility(value),
    do: enum_value(value, [:private, :tenant], :invalid_visibility)

  defp enforce_direct_visibility(attrs, %Conversation{kind: :direct}) do
    Map.put(attrs, :visibility, :private)
  end

  defp enforce_direct_visibility(attrs, _), do: attrs

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

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

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

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

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
