defmodule CommsCore.Conversations do
  import Ecto.Query

  @default_channel_limit 25
  @max_channel_limit 100

  alias CommsCore.{
    Accounts,
    Administration,
    AdmissionQuotas,
    AudioCalls,
    Outbox,
    Repo,
    ServiceAccounts
  }

  alias CommsCore.Accounts.{
    ConversationBootstrapPort,
    InitialConversationCommand,
    InitialConversationReceipt
  }

  alias CommsCore.Audit

  alias CommsCore.Conversations.{
    AdmissionUsage,
    Conversation,
    ConversationView,
    Membership,
    MessageWriteSlot
  }

  @behaviour ConversationBootstrapPort

  @doc """
  Implements the IdentityAccess bootstrap port inside the caller's transaction.

  Both rows remain owned and persisted by Conversations. The returned receipt
  contains only the IdentityAccess-owned bootstrap projection fields.
  """
  @impl ConversationBootstrapPort
  def create_initial_channel(%InitialConversationCommand{} = command) do
    if Repo.in_transaction?() do
      with {:ok, conversation} <- persist_initial_tenant_channel(Repo, command) do
        {:ok, initial_conversation_receipt(conversation, command.owner_user_id)}
      end
    else
      {:error, :transaction_required}
    end
  end

  @impl ConversationBootstrapPort
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

  @doc """
  Lists active conversations for a service identity with directory scope.

  IdentityAccess validates the durable service credential and scope;
  Conversations owns membership and archive filtering and returns only views.
  """
  @spec list_for_service(map()) :: {:ok, [ConversationView.t()]} | {:error, :forbidden}
  def list_for_service(subject) when is_map(subject) do
    with :ok <- ServiceAccounts.authorize_service(subject, "conversations:read") do
      {:ok, list_for_user_views(subject)}
    end
  end

  def list_for_service(_subject), do: {:error, :forbidden}

  @doc """
  Authorizes a scoped service identity against owner-local conversation state.

  The credential and requested capability are revalidated by IdentityAccess.
  Conversations then requires an active same-tenant membership and a
  non-archived conversation. Every failure is intentionally indistinguishable.
  """
  @spec authorize_service_access(map(), String.t(), Ecto.UUID.t()) ::
          :ok | {:error, :forbidden}
  def authorize_service_access(subject, required_scope, conversation_id)
      when is_map(subject) and is_binary(required_scope) and is_binary(conversation_id) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         :ok <- ServiceAccounts.authorize_service(subject, required_scope),
         true <- active_service_membership?(subject, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_service_access(_subject, _required_scope, _conversation_id),
    do: {:error, :forbidden}

  @doc """
  Authorizes creation using the active identity projection owned by
  `CommsCore.Accounts`.
  """
  @spec authorize_create(map()) :: :ok | {:error, :forbidden}
  def authorize_create(subject) when is_map(subject) do
    with {:ok, _grant} <- Accounts.access_grant(subject), do: :ok
  end

  def authorize_create(_subject), do: {:error, :forbidden}

  @doc """
  Authorizes discovery of tenant-visible channels without exposing either
  identity or conversation persistence structs.
  """
  @spec authorize_discovery(map()) ::
          :ok | {:error, :forbidden | :public_channels_disabled}
  def authorize_discovery(subject) when is_map(subject) do
    with {:ok, _grant} <- Accounts.access_grant(subject),
         :ok <- public_channels_enabled(subject) do
      :ok
    end
  end

  def authorize_discovery(_subject), do: {:error, :forbidden}

  @doc """
  Authorizes self-service entry into a tenant-visible channel.
  """
  @spec authorize_join(Ecto.UUID.t(), map()) ::
          :ok | {:error, :forbidden | :public_channels_disabled}
  def authorize_join(conversation_id, subject),
    do: authorize_public_channel(:join, conversation_id, subject)

  @doc """
  Authorizes self-service departure from a tenant-visible channel.

  Disabling public channels intentionally does not trap existing members.
  """
  @spec authorize_leave(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_leave(conversation_id, subject),
    do: authorize_public_channel(:leave, conversation_id, subject)

  @doc "Authorizes access that requires an active conversation membership."
  @spec authorize_read(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_read(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc "Authorizes sending message content to a conversation."
  @spec authorize_send_message(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_send_message(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc "Authorizes advancing the subject's read cursor."
  @spec authorize_mark_read(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_mark_read(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc "Authorizes reacting to message content in a conversation."
  @spec authorize_react_message(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_react_message(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc "Authorizes attaching content to a conversation."
  @spec authorize_upload_attachment(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_upload_attachment(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  @doc """
  Authorizes ordinary conversation administration.

  Conversation owners and moderators may manage any conversation they actively
  belong to. Tenant owners and administrators may additionally manage
  tenant-visible channels. Denials for an otherwise active identity are
  recorded through the Audit facade.
  """
  @spec authorize_manage(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_manage(conversation_id, subject),
    do: authorize_management(:manage_conversation, conversation_id, subject)

  @doc """
  Authorizes ownership changes using the stricter owner policy.
  """
  @spec authorize_manage_ownership(Ecto.UUID.t(), map()) :: :ok | {:error, :forbidden}
  def authorize_manage_ownership(conversation_id, subject),
    do: authorize_management(:manage_conversation_ownership, conversation_id, subject)

  @doc """
  Returns conversation-owned capacity counts for approved read-model composition.
  """
  @spec admission_usage(Ecto.UUID.t()) :: AdmissionUsage.t()
  def admission_usage(tenant_id) when is_binary(tenant_id) do
    {active_conversations, largest_conversation_members} =
      admission_usage_counts(tenant_id)

    %AdmissionUsage{
      active_conversations: active_conversations,
      largest_conversation_members: largest_conversation_members
    }
  end

  @doc """
  Archives a tenant-scoped conversation as part of an existing erasure transaction.

  Returns the number of archived rows and never exposes the Conversation schema.
  """
  @spec archive_for_erasure(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_erasure_scope | :transaction_required}
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

  @doc """
  Ends a user's active tenant memberships as part of an existing erasure transaction.

  Returns the number of memberships changed and never exposes Membership schemas.
  """
  @spec remove_user_memberships_for_erasure(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_erasure_scope | :transaction_required}
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

  @doc """
  Reserves the next message sequence while participating in the caller's transaction.

  This owner-contributed operation keeps the conversation row lock and mutation
  inside Conversations. The surrounding transaction must roll back if later
  message-content work fails.
  """
  @spec reserve_message_slot(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MessageWriteSlot.t()}
          | {:error, :conversation_not_found | :transaction_required | Ecto.Changeset.t()}
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

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    else
      {:error, :transaction_required}
    end
  end

  def reserve_message_slot(_tenant_id, _conversation_id),
    do: {:error, :conversation_not_found}

  @doc """
  Validates that every supplied user is an active member of the conversation.

  Membership persistence stays inside Conversations. IdentityAccess resolves
  active user IDs through its facade; content callers exchange only identifiers
  and the validation result.
  """
  @spec validate_active_members(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          :ok | {:error, :invalid_mentions}
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

  @doc """
  Validates an exact tenant-scoped conversation reference.

  The result contains no conversation persistence details and intentionally
  treats malformed, missing, and foreign-tenant identifiers as not found.
  Archived conversations remain valid references while their row exists.
  """
  @spec validate_reference(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
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

  @doc """
  Returns every conversation ID in a tenant's retention scope.

  Archived conversations remain in scope, matching the durable conversation
  rows considered by retention processing. IDs are returned deterministically
  without exposing conversation persistence.
  """
  @spec retention_scope_ids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
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

  @doc """
  Returns the active conversation IDs visible to a subject.

  This is a read projection for content queries; callers do not receive
  conversation or membership persistence structs.
  """
  @spec active_conversation_ids(map()) :: [Ecto.UUID.t()]
  def active_conversation_ids(subject) when is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    Repo.all(
      from(conversation in Conversation,
        join: membership in Membership,
        on:
          membership.conversation_id == conversation.id and
            membership.tenant_id == conversation.tenant_id,
        where:
          conversation.tenant_id == ^tenant_id and membership.user_id == ^user_id and
            is_nil(membership.left_at) and is_nil(conversation.archived_at),
        select: conversation.id
      )
    )
  end

  @doc false
  def project(%Conversation{} = conversation),
    do: CommsCore.Conversations.Projector.conversation(conversation)

  def project(%ConversationView{} = conversation), do: conversation

  def create_view(attrs, subject),
    do:
      create(attrs, subject) |> project_result(&CommsCore.Conversations.Projector.conversation/1)

  def list_for_user_views(subject),
    do:
      subject
      |> list_for_user()
      |> Enum.map(&CommsCore.Conversations.Projector.user_conversation/1)

  def discover_public_channel_views(params, subject) do
    with {:ok, result} <- discover_public_channels(params, subject) do
      {:ok,
       %{
         result
         | channels:
             Enum.map(result.channels, &CommsCore.Conversations.Projector.public_channel/1)
       }}
    end
  end

  def join_public_channel_view(id, subject),
    do: join_public_channel(id, subject) |> project_result(&project_membership_change/1)

  def leave_public_channel_view(id, attrs, subject),
    do: leave_public_channel(id, attrs, subject) |> project_result(&project_membership_change/1)

  def get_for_user_view(id, subject),
    do:
      get_for_user(id, subject)
      |> project_result(&CommsCore.Conversations.Projector.user_conversation/1)

  def update_view(id, attrs, subject),
    do:
      __MODULE__.update(id, attrs, subject)
      |> project_result(&CommsCore.Conversations.Projector.conversation/1)

  def archive_view(id, attrs, subject),
    do:
      archive(id, attrs, subject)
      |> project_result(&CommsCore.Conversations.Projector.conversation/1)

  def list_member_views(id, subject) do
    with {:ok, members} <- list_members(id, subject) do
      {:ok, Enum.map(members, &CommsCore.Conversations.Projector.membership/1)}
    end
  end

  def add_member_view(conversation_id, user_id, role, subject),
    do:
      add_member(conversation_id, user_id, role, subject)
      |> project_result(&CommsCore.Conversations.Projector.membership/1)

  def remove_member_view(conversation_id, user_id, attrs, subject),
    do:
      remove_member(conversation_id, user_id, attrs, subject)
      |> project_result(&CommsCore.Conversations.Projector.membership/1)

  def change_member_role_view(conversation_id, user_id, attrs, subject),
    do:
      change_member_role(conversation_id, user_id, attrs, subject)
      |> project_result(&CommsCore.Conversations.Projector.membership/1)

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    kind = enum_value(value(attrs, :kind), [:direct, :group, :channel], :group)
    member_ids = normalize_member_ids(value(attrs, :member_ids), user_id)

    visibility = enum_value(value(attrs, :visibility), [:private, :tenant], :private)
    visibility = if kind == :direct, do: :private, else: visibility

    with :ok <- authorize_create(subject),
         :ok <- validate_members(tenant_id, member_ids),
         :ok <- validate_public_channel(subject, kind, visibility),
         {:ok, direct_key} <- direct_key(kind, member_ids) do
      now = now()

      Repo.transaction(fn ->
        policy = admission_policy!(tenant_id)
        current_active_conversations = active_conversation_count(tenant_id)

        quota_ok!(
          AdmissionQuotas.check_conversation_creation(
            policy,
            current_active_conversations,
            length(member_ids)
          )
        )

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

    with :ok <- authorize_discovery(subject),
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
    with :ok <- authorize_join(id, subject) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, subject, require_enabled: true)
        authorize_in_transaction!(fn -> authorize_join(conversation.id, subject) end)
        policy = admission_policy!(conversation.tenant_id)

        user_id = value(subject, :user_id)
        timestamp = now()

        {membership, replayed} =
          case lock_membership(conversation, user_id) do
            nil ->
              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

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
              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

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
    with :ok <- authorize_leave(id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_channel!(id, subject)
        ensure_public_channel!(conversation, subject, require_enabled: false)
        authorize_in_transaction!(fn -> authorize_leave(conversation.id, subject) end)
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

          audio_revocation_ok!(
            AudioCalls.revoke_for_membership(
              conversation.tenant_id,
              conversation.id,
              left_membership.user_id,
              "membership_left"
            )
          )

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
    with :ok <- authorize_manage(id, subject),
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

        case validate_public_channel(subject, conversation.kind, requested_visibility) do
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
    with :ok <- authorize_manage(id, subject),
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

        audio_revocation_ok!(
          AudioCalls.revoke_for_conversation(
            archived.tenant_id,
            archived.id,
            "conversation_archived"
          )
        )

        archived
      end)
      |> transaction_result()
    end
  end

  def list_members(conversation_id, subject) do
    with :ok <- authorize_read(conversation_id, subject) do
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

  @doc """
  Returns the active member user IDs for a tenant-scoped conversation.

  Results are scalar IDs ordered deterministically; membership persistence
  details remain internal to Conversations.
  """
  @spec active_member_ids(Ecto.UUID.t(), Ecto.UUID.t()) :: [Ecto.UUID.t()]
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

  def add_member(conversation_id, user_id, role, subject) do
    with :ok <- authorize_manage(conversation_id, subject),
         {:ok, assigned_role} <- membership_role(role) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(fn -> authorize_manage(conversation.id, subject) end)
        policy = admission_policy!(conversation.tenant_id)

        unless Accounts.resolve_active_user_ids(conversation.tenant_id, [user_id]) == [user_id],
          do: Repo.rollback(:invalid_member)

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

              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

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

              quota_ok!(ensure_conversation_member_capacity(policy, conversation))

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
    with :ok <- authorize_manage(conversation_id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(fn -> authorize_manage(conversation.id, subject) end)
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

        audio_revocation_ok!(
          AudioCalls.revoke_for_membership(
            conversation.tenant_id,
            conversation.id,
            updated.user_id,
            "membership_removed"
          )
        )

        updated
      end)
      |> transaction_result()
    end
  end

  def change_member_role(conversation_id, user_id, attrs, subject) when is_map(attrs) do
    with :ok <- authorize_manage(conversation_id, subject),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, role} <- membership_role(value(attrs, :role)) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)
        authorize_in_transaction!(fn -> authorize_manage(conversation.id, subject) end)

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
    with :ok <- authorize_mark_read(conversation_id, subject),
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

    Audit.record(%{
      tenant_id: conversation.tenant_id,
      actor_user_id: value(subject, :user_id),
      action: String.replace(type, ".v1", ""),
      resource_type: "conversation",
      resource_id: conversation.id,
      metadata: payload,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp validate_members(tenant_id, member_ids) do
    active_user_ids = Accounts.resolve_active_user_ids(tenant_id, member_ids)

    if MapSet.new(active_user_ids) == MapSet.new(member_ids),
      do: :ok,
      else: {:error, :invalid_members}
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

  defp authorize_public_channel(action, conversation_id, subject)
       when action in [:join, :leave] and is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil} <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: grant.tenant_id
           ),
         :ok <- maybe_require_public_channels_enabled(action, subject) do
      :ok
    else
      {:error, :public_channels_disabled} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_public_channel(_action, _conversation_id, _subject),
    do: {:error, :forbidden}

  defp authorize_active_membership(conversation_id, subject)
       when is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         %Membership{} <- active_membership(grant, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_active_membership(_conversation_id, _subject),
    do: {:error, :forbidden}

  defp authorize_management(action, conversation_id, subject)
       when action in [:manage_conversation, :manage_conversation_ownership] and
              is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject) do
      authorization =
        with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
             %Conversation{} = conversation <-
               Repo.get_by(Conversation,
                 id: conversation_id,
                 tenant_id: grant.tenant_id
               ) do
          membership = active_membership(grant, conversation_id)

          case {action, grant.role, membership, conversation} do
            {:manage_conversation, _tenant_role, %Membership{role: role}, _conversation}
            when role in [:owner, :moderator] ->
              :ok

            {:manage_conversation_ownership, _tenant_role, %Membership{role: :owner},
             _conversation} ->
              :ok

            {_action, role, _membership, %Conversation{kind: :channel, visibility: :tenant}}
            when role in [:owner, :admin] ->
              :ok

            _ ->
              {:error, :forbidden}
          end
        else
          _ -> {:error, :forbidden}
        end

      case authorization do
        :ok -> :ok
        {:error, :forbidden} -> deny_conversation_management(action, grant, subject)
      end
    else
      {:error, _reason} ->
        Accounts.audit_authorization_denial(action, subject, :forbidden)
    end
  end

  defp authorize_management(_action, _conversation_id, _subject),
    do: {:error, :forbidden}

  defp active_membership(grant, conversation_id) do
    Repo.one(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.conversation_id == ^conversation_id and
            membership.user_id == ^grant.user_id and
            membership.tenant_id == ^grant.tenant_id and
            conversation.tenant_id == ^grant.tenant_id and
            is_nil(membership.left_at) and is_nil(conversation.archived_at)
      )
    )
  end

  defp maybe_require_public_channels_enabled(:join, subject),
    do: public_channels_enabled(subject)

  defp maybe_require_public_channels_enabled(:leave, _subject), do: :ok

  defp public_channels_enabled(subject) do
    case Administration.member_capabilities(subject) do
      {:ok, %{allow_public_channels: false}} -> {:error, :public_channels_disabled}
      {:ok, %{allow_public_channels: true}} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp deny_conversation_management(action, _grant, subject),
    do: Accounts.audit_authorization_denial(action, subject, :forbidden)

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
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil},
         subject,
         require_enabled: require_enabled
       ) do
    if require_enabled do
      case validate_public_channel(subject, :channel, :tenant) do
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

  defp authorize_in_transaction!(authorization) when is_function(authorization, 0) do
    case authorization.() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_ownership_change!(current_role, requested_role, subject, conversation)
       when current_role == :owner or requested_role == :owner do
    authorize_in_transaction!(fn -> authorize_manage_ownership(conversation.id, subject) end)
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

  defp validate_public_channel(subject, :channel, :tenant),
    do: public_channels_enabled(subject)

  defp validate_public_channel(_subject, _kind, _visibility), do: :ok

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
  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp project_membership_change(result) do
    %{
      conversation: CommsCore.Conversations.Projector.conversation(result.conversation),
      membership: CommsCore.Conversations.Projector.membership(result.membership),
      replayed: result.replayed
    }
  end

  defp audio_revocation_ok!({:ok, _count}), do: :ok
  defp audio_revocation_ok!({:error, reason}), do: Repo.rollback(reason)

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

  defp admission_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp active_conversation_count(tenant_id) do
    Conversation
    |> where(
      [conversation],
      conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at)
    )
    |> Repo.aggregate(:count)
  end

  defp admission_usage_counts(tenant_id) do
    active_member_counts =
      from(conversation in Conversation,
        left_join: membership in Membership,
        on:
          membership.tenant_id == conversation.tenant_id and
            membership.conversation_id == conversation.id and is_nil(membership.left_at),
        where: conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at),
        group_by: conversation.id,
        select: %{member_count: count(membership.id)}
      )

    from(counts in subquery(active_member_counts),
      select: {count(counts.member_count), fragment("COALESCE(MAX(?), 0)", counts.member_count)}
    )
    |> Repo.one()
  end

  defp ensure_conversation_member_capacity(policy, %Conversation{} = conversation) do
    current_active_members =
      Membership
      |> join(:inner, [membership], joined_conversation in Conversation,
        on:
          joined_conversation.id == membership.conversation_id and
            joined_conversation.tenant_id == membership.tenant_id
      )
      |> where(
        [membership, joined_conversation],
        membership.tenant_id == ^conversation.tenant_id and
          membership.conversation_id == ^conversation.id and
          joined_conversation.tenant_id == ^conversation.tenant_id and
          is_nil(joined_conversation.archived_at) and is_nil(membership.left_at)
      )
      |> Repo.aggregate(:count)

    AdmissionQuotas.check_conversation_member_capacity(policy, current_active_members)
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

  defp active_service_membership?(subject, conversation_id) do
    Repo.exists?(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.tenant_id == ^value(subject, :tenant_id) and
            membership.user_id == ^value(subject, :user_id) and
            membership.conversation_id == ^conversation_id and is_nil(membership.left_at) and
            is_nil(conversation.archived_at)
      )
    )
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
