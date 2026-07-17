defmodule CommsCore.Messaging do
  import Ecto.Query

  alias CommsCore.{Attachments, Authorization, Conversations, Outbox, Repo, ServiceAccounts}
  alias CommsCore.Audit
  alias CommsCore.Conversations.MessageWriteSlot

  alias CommsCore.Messaging.{
    Message,
    MessageDeletionCandidate,
    MessageMention,
    MessageRevision,
    MessageView,
    Projector,
    Reaction
  }

  @max_metadata_bytes 65_536
  @default_search_limit 50
  @max_search_limit 200
  @required [:tenant_id, :conversation_id, :sender_user_id, :sender_device_id, :client_message_id]

  @doc """
  Tombstones tenant-scoped messages as part of an existing erasure transaction.

  Revision and reaction history is removed before message content is scrubbed.
  Returns only affected-row counts and never exposes content persistence schemas.
  """
  @spec tombstone_for_erasure(Ecto.UUID.t(), [Ecto.UUID.t()], DateTime.t()) ::
          {:ok,
           %{
             messages_tombstoned: non_neg_integer(),
             revisions_deleted: non_neg_integer(),
             reactions_deleted: non_neg_integer()
           }}
          | {:error, :invalid_erasure_scope | :transaction_required}
  def tombstone_for_erasure(tenant_id, message_ids, %DateTime{} = timestamp)
      when is_binary(tenant_id) and is_list(message_ids) do
    if Repo.in_transaction?() do
      message_ids = Enum.uniq(message_ids)

      with :ok <- validate_erasure_scope(tenant_id, message_ids) do
        {revisions_deleted, _} =
          Repo.delete_all(
            from(revision in MessageRevision,
              where: revision.tenant_id == ^tenant_id and revision.message_id in ^message_ids
            )
          )

        {reactions_deleted, _} =
          Repo.delete_all(
            from(reaction in Reaction,
              where: reaction.tenant_id == ^tenant_id and reaction.message_id in ^message_ids
            )
          )

        {messages_tombstoned, _} =
          Repo.update_all(
            from(message in Message,
              where: message.tenant_id == ^tenant_id and message.id in ^message_ids
            ),
            set: [body: nil, metadata: %{}, status: :deleted, deleted_at: timestamp]
          )

        {:ok,
         %{
           messages_tombstoned: messages_tombstoned,
           revisions_deleted: revisions_deleted,
           reactions_deleted: reactions_deleted
         }}
      end
    else
      {:error, :transaction_required}
    end
  end

  def tombstone_for_erasure(_tenant_id, _message_ids, _timestamp),
    do: {:error, :invalid_erasure_scope}

  @doc """
  Lists message history for an authenticated service identity.

  ConversationContent owns the query and projection. IdentityAccess validates
  service-account scope, while Conversations owns membership and archive
  authorization.
  """
  @spec list_service_history(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, [MessageView.t()]} | {:error, term()}
  def list_service_history(conversation_id, subject, opts \\ [])
      when is_binary(conversation_id) and is_map(subject) and is_list(opts) do
    with :ok <-
           Conversations.authorize_service_access(subject, "messages:read", conversation_id) do
      list_history(
        conversation_id,
        subject,
        Keyword.put(opts, :authorize, &service_authorizer/3)
      )
    end
  end

  @doc """
  Accepts a service-authored message through the ConversationContent owner.

  Service identities cannot attach files. Authorization is rechecked inside
  the existing message transaction so idempotent replay semantics are retained.
  """
  @spec accept_service_message_with_status(Ecto.UUID.t(), map(), map()) ::
          {:ok, MessageView.t(), :created | :duplicate} | {:error, term()}
  def accept_service_message_with_status(conversation_id, attrs, subject)
      when is_binary(conversation_id) and is_map(attrs) and is_map(subject) do
    with :ok <- reject_service_attachments(attrs),
         :ok <-
           Conversations.authorize_service_access(subject, "messages:write", conversation_id) do
      message_attrs =
        attrs
        |> Map.put(:tenant_id, value(subject, :tenant_id))
        |> Map.put(:conversation_id, conversation_id)
        |> Map.put(:sender_user_id, value(subject, :user_id))
        |> Map.put(:sender_device_id, value(subject, :device_id))
        |> Map.put(:attachment_ids, [])

      accept_message_with_status(message_attrs, subject, authorize: &service_authorizer/3)
    end
  end

  @doc """
  Searches message content visible to a scoped service identity.
  """
  @spec search_for_service(String.t(), map(), keyword()) ::
          {:ok, [MessageView.t()]} | {:error, term()}
  def search_for_service(query, subject, opts \\ [])
      when is_binary(query) and is_map(subject) and is_list(opts) do
    with :ok <- ServiceAccounts.authorize_service(subject, "search:read") do
      query_text = String.trim(query)

      if query_text == "" do
        {:ok, []}
      else
        limit_count = opts |> Keyword.get(:limit, 50) |> integer(50) |> max(1) |> min(100)
        search(query_text, subject, limit: limit_count)
      end
    end
  end

  def accept_message(attrs, subject, opts \\ []) when is_map(attrs) and is_map(subject) do
    case accept_message_with_status(attrs, subject, opts) do
      {:ok, message, _status} -> {:ok, message}
      {:error, _reason} = error -> error
    end
  end

  def accept_message_with_status(attrs, subject, opts \\ [])
      when is_map(attrs) and is_map(subject) do
    attrs = normalize(attrs)
    authorize = Keyword.get(opts, :authorize, &Authorization.authorize/3)

    with :ok <- validate_identity(attrs, subject),
         :ok <- validate(attrs) do
      case Repo.transaction(fn -> accept_in_transaction(attrs, subject, authorize) end) do
        {:ok, {message, status}} -> {:ok, message, status}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def list_after(tenant_id, conversation_id, after_sequence \\ 0, limit \\ 100) do
    Message
    |> where(
      [m],
      m.tenant_id == ^tenant_id and m.conversation_id == ^conversation_id and
        m.conversation_sequence > ^after_sequence
    )
    |> order_by([m], asc: m.conversation_sequence)
    |> limit(^clamp_limit(limit))
    |> Repo.all()
    |> hydrate_messages()
  end

  def list_history(conversation_id, subject, opts \\ []) do
    authorize = Keyword.get(opts, :authorize, &Authorization.authorize/3)

    with :ok <- authorize.(:read_conversation, subject, %{id: conversation_id}) do
      after_sequence = integer(Keyword.get(opts, :after_sequence, 0), 0)
      before_sequence = Keyword.get(opts, :before_sequence)
      max_limit = if Keyword.get(opts, :probe_more, false), do: 501, else: 500
      limit_count = clamp_limit(Keyword.get(opts, :limit, 100), max_limit)

      query =
        Message
        |> where(
          [m],
          m.tenant_id == ^value(subject, :tenant_id) and
            m.conversation_id == ^conversation_id and
            m.conversation_sequence > ^after_sequence
        )
        |> maybe_before(before_sequence)
        |> order_by([m], asc: m.conversation_sequence)
        |> limit(^limit_count)

      {:ok, query |> Repo.all() |> hydrate_messages()}
    end
  end

  def get_thread(conversation_id, message_id, subject, opts \\ []) do
    target =
      Repo.get_by(Message,
        id: message_id,
        tenant_id: value(subject, :tenant_id),
        conversation_id: conversation_id
      )

    with %Message{} = target <- target,
         :ok <- Authorization.authorize(:read_conversation, subject, %{id: conversation_id}) do
      root_id = target.thread_root_message_id || target.id
      limit_count = clamp_limit(Keyword.get(opts, :limit, 50), 100)
      before_sequence = integer(Keyword.get(opts, :before_sequence), nil)

      root =
        Repo.get_by!(Message,
          id: root_id,
          tenant_id: value(subject, :tenant_id),
          conversation_id: conversation_id
        )
        |> hydrate_message()

      replies_query =
        from(message in Message,
          where:
            message.tenant_id == ^value(subject, :tenant_id) and
              message.conversation_id == ^conversation_id and
              message.thread_root_message_id == ^root_id,
          order_by: [desc: message.conversation_sequence],
          limit: ^(limit_count + 1)
        )
        |> maybe_thread_before(before_sequence)

      fetched = replies_query |> Repo.all() |> hydrate_messages()
      has_more = length(fetched) > limit_count
      replies = fetched |> Enum.take(limit_count) |> Enum.reverse()

      next_before_sequence =
        if has_more,
          do: replies |> List.first() |> then(&if(&1, do: &1.conversation_sequence)),
          else: nil

      {:ok,
       %{
         root: root,
         replies: replies,
         reply_count: root.thread_reply_count,
         has_more: has_more,
         next_before_sequence: next_before_sequence
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def edit_message(message_id, body, subject) when is_binary(body) do
    body = String.trim(body)

    with :ok <- validate_body(body) do
      Repo.transaction(fn ->
        message = locked_message(message_id, subject)

        case Authorization.authorize(:edit_message, subject, message) do
          :ok ->
            revision = revision_number(message.id)

            %MessageRevision{}
            |> MessageRevision.changeset(%{
              tenant_id: message.tenant_id,
              message_id: message.id,
              editor_user_id: value(subject, :user_id),
              body: message.body,
              revision: revision
            })
            |> Repo.insert!()

            updated =
              message
              |> Message.edit_changeset(%{body: body, edited_at: now()})
              |> Repo.update!()

            insert_event(updated, "message.updated.v1", subject, %{
              conversation_sequence: updated.conversation_sequence,
              revision: revision
            })

            hydrate_message(updated)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  def edit_message(_, _, _), do: {:error, :invalid_message_body}

  @doc """
  Contributes an authorized message deletion to a caller-owned policy transaction.

  The policy callback receives a `MessageDeletionCandidate`, never the Message
  schema. This keeps the content mutation inside its owner while allowing
  Governance to enforce legal holds before the update and outbox append.
  """
  @spec delete_message(
          Ecto.UUID.t(),
          map(),
          (MessageDeletionCandidate.t() -> :ok | {:error, term()})
        ) ::
          {:ok, CommsCore.Messaging.MessageView.t()}
          | {:error, :not_found | :transaction_required | term()}
  def delete_message(message_id, subject, policy_check)
      when is_map(subject) and is_function(policy_check, 1) do
    if Repo.in_transaction?() do
      with %Message{} = message <- locked_message(message_id, subject),
           :ok <- Authorization.authorize(:delete_message, subject, message),
           :ok <-
             policy_check.(%MessageDeletionCandidate{
               id: message.id,
               tenant_id: message.tenant_id,
               conversation_id: message.conversation_id,
               sender_user_id: message.sender_user_id
             }),
           {:ok, updated} <-
             message
             |> Message.delete_changeset(%{body: nil, status: :deleted, deleted_at: now()})
             |> Repo.update() do
        insert_event(updated, "message.deleted.v1", subject, %{
          conversation_sequence: updated.conversation_sequence
        })

        {:ok, hydrate_message(updated)}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    else
      {:error, :transaction_required}
    end
  end

  def delete_message(_message_id, _subject, _policy_check), do: {:error, :not_found}

  def add_reaction(message_id, emoji, subject) when is_binary(emoji) do
    with %Message{} = message <- scoped_message(message_id, subject),
         :ok <- Authorization.authorize(:react_message, subject, message) do
      changeset =
        Reaction.changeset(%Reaction{}, %{
          tenant_id: message.tenant_id,
          message_id: message.id,
          user_id: value(subject, :user_id),
          emoji: emoji
        })

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:message_id, :user_id, :emoji],
             returning: true
           ) do
        {:ok, reaction} -> {:ok, Projector.reaction(reaction)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def remove_reaction(message_id, emoji, subject) do
    with %Message{} = message <- scoped_message(message_id, subject),
         :ok <- Authorization.authorize(:react_message, subject, message) do
      query =
        from(r in Reaction,
          where:
            r.message_id == ^message_id and r.tenant_id == ^value(subject, :tenant_id) and
              r.user_id == ^value(subject, :user_id) and r.emoji == ^emoji
        )

      case Repo.delete_all(query) do
        {1, _} -> :ok
        _ -> {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def search(query_text, subject, opts \\ []) when is_binary(query_text) do
    case search_page(query_text, subject, opts) do
      {:ok, %{messages: messages}} -> {:ok, messages}
      {:error, _reason} = error -> error
    end
  end

  def search_page(query_text, subject, opts \\ [])
      when is_binary(query_text) and is_map(subject) and is_list(opts) do
    query_text = String.trim(query_text)
    limit_count = clamp_limit(Keyword.get(opts, :limit, @default_search_limit), @max_search_limit)

    if query_text == "" do
      {:ok, %{messages: [], limit: limit_count, has_more: false, next_cursor: nil}}
    else
      with {:ok, conversation_id} <- optional_search_uuid(Keyword.get(opts, :conversation_id)),
           {:ok, sender_user_id} <- optional_search_uuid(Keyword.get(opts, :sender_user_id)),
           {:ok, after_at} <- optional_search_datetime(Keyword.get(opts, :after)),
           {:ok, before_at} <- optional_search_datetime(Keyword.get(opts, :before)),
           :ok <- validate_search_range(after_at, before_at),
           {:ok, cursor} <- optional_search_cursor(Keyword.get(opts, :cursor)) do
        active_conversation_ids = Conversations.active_conversation_ids(subject)

        results =
          from(m in Message,
            where:
              m.tenant_id == ^value(subject, :tenant_id) and
                m.conversation_id in ^active_conversation_ids and
                m.status == :active and
                fragment(
                  "to_tsvector('simple', coalesce(?, '')) @@ plainto_tsquery('simple', ?)",
                  m.body,
                  ^query_text
                ),
            order_by: [desc: m.inserted_at, desc: m.id],
            preload: []
          )
          |> maybe_filter_search(:conversation_id, conversation_id)
          |> maybe_filter_search(:sender_user_id, sender_user_id)
          |> maybe_filter_search(:after, after_at)
          |> maybe_filter_search(:before, before_at)
          |> maybe_before_search_cursor(cursor)
          |> limit(^(limit_count + 1))
          |> Repo.all()

        has_more = length(results) > limit_count
        messages = results |> Enum.take(limit_count) |> hydrate_messages()

        {:ok,
         %{
           messages: messages,
           limit: limit_count,
           has_more: has_more,
           next_cursor: if(has_more, do: search_cursor_for(List.last(messages)), else: nil)
         }}
      end
    end
  end

  defp accept_in_transaction(attrs, subject, authorize) do
    :ok = lock_idempotency_key(attrs)

    case existing(attrs) do
      %Message{} = message -> authorize_existing(message, subject, authorize)
      nil -> {persist_new(attrs, subject, authorize), :created}
    end
  end

  defp authorize_existing(message, subject, authorize) do
    target = %{id: message.conversation_id, tenant_id: message.tenant_id}

    case authorize.(:send_message, subject, target) do
      :ok -> {hydrate_message(message), :duplicate}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp service_authorizer(:send_message, subject, %{id: id}),
    do: Conversations.authorize_service_access(subject, "messages:write", id)

  defp service_authorizer(:read_conversation, subject, %{id: id}),
    do: Conversations.authorize_service_access(subject, "messages:read", id)

  defp service_authorizer(_, _, _), do: {:error, :forbidden}

  defp lock_idempotency_key(attrs) do
    lock_key =
      {attrs.tenant_id, attrs.sender_device_id, attrs.client_message_id}
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      [lock_key]
    )

    :ok
  end

  defp persist_new(attrs, subject, authorize) do
    slot =
      case Conversations.reserve_message_slot(attrs.tenant_id, attrs.conversation_id) do
        {:ok, %MessageWriteSlot{} = slot} -> slot
        {:error, reason} -> Repo.rollback(reason)
      end

    with :ok <- authorize.(:send_message, subject, slot),
         {:ok, thread_root_message_id} <- resolve_thread_root(attrs, slot),
         :ok <- validate_mentions(attrs, slot) do
      attrs = Map.put(attrs, :thread_root_message_id, thread_root_message_id)
      persist(attrs, subject, slot)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp existing(attrs) do
    Repo.one(
      from(m in Message,
        where:
          m.tenant_id == ^attrs.tenant_id and
            m.sender_device_id == ^attrs.sender_device_id and
            m.client_message_id == ^attrs.client_message_id
      )
    )
  end

  defp persist(attrs, subject, %MessageWriteSlot{sequence: sequence}) do
    message =
      %Message{}
      |> Message.changeset(Map.merge(attrs, %{conversation_sequence: sequence, status: :active}))
      |> Repo.insert!()

    :ok =
      Attachments.attach_ready(
        attrs.attachment_ids,
        message.id,
        message.tenant_id,
        subject
      )

    persist_mentions(message, attrs.mentioned_user_ids)

    insert_event(message, "message.created.v1", subject, %{
      conversation_sequence: sequence,
      sender_user_id: message.sender_user_id,
      reply_to_message_id: message.reply_to_message_id,
      thread_root_message_id: message.thread_root_message_id,
      mentioned_user_ids: attrs.mentioned_user_ids,
      body: message.body
    })

    if attrs.mentioned_user_ids != [] do
      insert_event(message, "mention.created.v1", subject, %{
        conversation_sequence: sequence,
        sender_user_id: message.sender_user_id,
        thread_root_message_id: message.thread_root_message_id,
        mentioned_user_ids: attrs.mentioned_user_ids
      })
    end

    hydrate_message(message)
  end

  defp insert_event(message, event_type, subject, payload) do
    timestamp = now()

    Outbox.insert_and_enqueue!(%{
      tenant_id: message.tenant_id,
      event_type: event_type,
      aggregate_type: "message",
      aggregate_id: message.id,
      payload:
        payload
        |> Map.put(:id, message.id)
        |> Map.put(:conversation_id, message.conversation_id),
      available_at: timestamp
    })

    Audit.record(%{
      tenant_id: message.tenant_id,
      actor_user_id: value(subject, :user_id),
      action: String.replace(event_type, ".v1", ""),
      resource_type: "message",
      resource_id: message.id,
      metadata:
        payload
        |> Map.drop([:body])
        |> Map.put(:conversation_id, message.conversation_id),
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp locked_message(message_id, subject) do
    Repo.one(
      from(m in Message,
        where: m.id == ^message_id and m.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp scoped_message(message_id, subject) do
    Repo.get_by(Message, id: message_id, tenant_id: value(subject, :tenant_id))
  end

  defp revision_number(message_id) do
    MessageRevision
    |> where([r], r.message_id == ^message_id)
    |> select([r], fragment("COALESCE(MAX(?), 0) + 1", r.revision))
    |> Repo.one()
  end

  defp validate_identity(attrs, subject) do
    expected = {
      value(subject, :tenant_id),
      value(subject, :user_id),
      value(subject, :device_id)
    }

    actual = {attrs.tenant_id, attrs.sender_user_id, attrs.sender_device_id}
    if expected == actual, do: :ok, else: {:error, :identity_mismatch}
  end

  defp validate(attrs) do
    missing = Enum.filter(@required, &(Map.get(attrs, &1) in [nil, ""]))
    body = Map.get(attrs, :body)
    body_validation = validate_body(body)

    cond do
      missing != [] ->
        {:error, {:missing_fields, missing}}

      body_validation != :ok ->
        body_validation

      invalid_optional_uuid?(attrs.reply_to_message_id) ->
        {:error, :invalid_reply_target}

      not is_list(attrs.mentioned_user_ids) ->
        {:error, :invalid_mentions}

      attrs.mentioned_user_count > 50 ->
        {:error, :too_many_mentions}

      Enum.any?(attrs.mentioned_user_ids, &invalid_uuid?/1) ->
        {:error, :invalid_mention_id}

      length(attrs.attachment_ids) > 20 ->
        {:error, :too_many_attachments}

      length(Enum.uniq(attrs.attachment_ids)) != length(attrs.attachment_ids) ->
        {:error, :duplicate_attachment_ids}

      Enum.any?(attrs.attachment_ids, &invalid_uuid?/1) ->
        {:error, :invalid_attachment_id}

      map_size(attrs.metadata) > 32 ->
        {:error, :metadata_too_many_properties}

      not metadata_size_valid?(attrs.metadata) ->
        {:error, :metadata_too_large}

      true ->
        :ok
    end
  end

  defp resolve_thread_root(%{reply_to_message_id: nil}, _conversation), do: {:ok, nil}

  defp resolve_thread_root(attrs, slot) do
    parent =
      Repo.one(
        from(message in Message,
          where:
            message.id == ^attrs.reply_to_message_id and
              message.tenant_id == ^slot.tenant_id and
              message.conversation_id == ^slot.id,
          lock: "FOR SHARE"
        )
      )

    case parent do
      %Message{} -> {:ok, parent.thread_root_message_id || parent.id}
      nil -> {:error, :invalid_reply_target}
    end
  end

  defp validate_mentions(%{mentioned_user_ids: []}, _slot), do: :ok

  defp validate_mentions(attrs, slot),
    do:
      Conversations.validate_active_members(
        slot.tenant_id,
        slot.id,
        attrs.mentioned_user_ids
      )

  defp persist_mentions(_message, []), do: :ok

  defp persist_mentions(message, mentioned_user_ids) do
    timestamp = now()

    rows =
      Enum.map(mentioned_user_ids, fn user_id ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: message.tenant_id,
          message_id: message.id,
          user_id: user_id,
          inserted_at: timestamp
        }
      end)

    Repo.insert_all(MessageMention, rows,
      on_conflict: :nothing,
      conflict_target: [:message_id, :user_id]
    )

    :ok
  end

  defp normalize(attrs) do
    keys = [
      :tenant_id,
      :conversation_id,
      :sender_user_id,
      :sender_device_id,
      :reply_to_message_id,
      :mentioned_user_ids,
      :client_message_id,
      :body,
      :metadata,
      :attachment_ids
    ]

    raw_mentions =
      Map.get(attrs, :mentioned_user_ids) || Map.get(attrs, "mentioned_user_ids") || []

    normalized =
      Map.new(keys, fn key ->
        {key, Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))}
      end)

    normalized
    |> Map.update(:body, nil, fn body -> if is_binary(body), do: String.trim(body), else: body end)
    |> Map.update(:metadata, %{}, fn value -> if is_map(value), do: value, else: %{} end)
    |> Map.update(:attachment_ids, [], fn value -> if is_list(value), do: value, else: [] end)
    |> Map.put(
      :mentioned_user_count,
      if(is_list(raw_mentions), do: length(raw_mentions), else: 0)
    )
    |> Map.put(
      :mentioned_user_ids,
      if(is_list(raw_mentions), do: Enum.uniq(raw_mentions), else: raw_mentions)
    )
  end

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, value) do
    case integer(value, nil) do
      nil -> query
      sequence -> where(query, [m], m.conversation_sequence < ^sequence)
    end
  end

  defp maybe_thread_before(query, nil), do: query

  defp maybe_thread_before(query, sequence) do
    where(query, [message], message.conversation_sequence < ^sequence)
  end

  defp optional_search_uuid(nil), do: {:ok, nil}
  defp optional_search_uuid(""), do: {:ok, nil}

  defp optional_search_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_search_query}
    end
  end

  defp optional_search_uuid(_value), do: {:error, :invalid_search_query}

  defp optional_search_datetime(nil), do: {:ok, nil}
  defp optional_search_datetime(""), do: {:ok, nil}

  defp optional_search_datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp optional_search_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, DateTime.truncate(timestamp, :microsecond)}
      {:error, _reason} -> {:error, :invalid_search_query}
    end
  end

  defp optional_search_datetime(_value), do: {:error, :invalid_search_query}

  defp validate_search_range(nil, _before_at), do: :ok
  defp validate_search_range(_after_at, nil), do: :ok

  defp validate_search_range(after_at, before_at) do
    if DateTime.compare(after_at, before_at) == :lt,
      do: :ok,
      else: {:error, :invalid_search_query}
  end

  defp optional_search_cursor(nil), do: {:ok, nil}
  defp optional_search_cursor(""), do: {:ok, nil}

  defp optional_search_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"inserted_at" => inserted_at, "id" => id, "v" => 1}} <- Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(inserted_at),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {DateTime.truncate(timestamp, :microsecond), uuid}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_search_cursor(_value), do: {:error, :invalid_cursor}

  defp maybe_filter_search(query, _field, nil), do: query

  defp maybe_filter_search(query, :conversation_id, value),
    do: where(query, [message, ...], message.conversation_id == ^value)

  defp maybe_filter_search(query, :sender_user_id, value),
    do: where(query, [message, ...], message.sender_user_id == ^value)

  defp maybe_filter_search(query, :after, value),
    do: where(query, [message, ...], message.inserted_at >= ^value)

  defp maybe_filter_search(query, :before, value),
    do: where(query, [message, ...], message.inserted_at < ^value)

  defp maybe_before_search_cursor(query, nil), do: query

  defp maybe_before_search_cursor(query, {timestamp, id}) do
    where(
      query,
      [message, ...],
      message.inserted_at < ^timestamp or
        (message.inserted_at == ^timestamp and message.id < ^id)
    )
  end

  defp search_cursor_for(nil), do: nil

  defp search_cursor_for(message) do
    %{v: 1, inserted_at: DateTime.to_iso8601(message.inserted_at), id: message.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp hydrate_message(%Message{} = message) do
    [hydrated] = hydrate_messages([message])
    hydrated
  end

  defp hydrate_messages([]), do: []

  defp hydrate_messages(messages) do
    messages = Repo.preload(messages, [:attachments, :reactions, :mentions], force: true)

    root_ids =
      messages
      |> Enum.map(&(&1.thread_root_message_id || &1.id))
      |> Enum.uniq()

    counts =
      Repo.all(
        from(message in Message,
          where: message.thread_root_message_id in ^root_ids,
          group_by: message.thread_root_message_id,
          select: {message.thread_root_message_id, count(message.id)}
        )
      )
      |> Map.new()

    Enum.map(messages, fn message ->
      root_id = message.thread_root_message_id || message.id
      Projector.message(message, Map.get(counts, root_id, 0))
    end)
  end

  defp validate_body(body) when not is_binary(body), do: {:error, :message_body_required}

  defp validate_body(body) do
    cond do
      body == "" -> {:error, :message_body_required}
      String.length(body) > 65_535 -> {:error, :message_too_large}
      true -> :ok
    end
  end

  defp reject_service_attachments(attrs) do
    case value(attrs, :attachment_ids) do
      nil -> :ok
      [] -> :ok
      _ -> {:error, :invalid_attachments}
    end
  end

  defp invalid_uuid?(value) do
    not (is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value)))
  end

  defp invalid_optional_uuid?(nil), do: false
  defp invalid_optional_uuid?(value), do: invalid_uuid?(value)

  defp metadata_size_valid?(metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> byte_size(encoded) <= @max_metadata_bytes
      {:error, _reason} -> false
    end
  end

  defp clamp_limit(value), do: clamp_limit(value, 500)
  defp clamp_limit(value, max_limit), do: value |> integer(100) |> max(1) |> min(max_limit)
  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp validate_erasure_scope(tenant_id, ids) do
    if valid_uuid?(tenant_id) and Enum.all?(ids, &valid_uuid?/1),
      do: :ok,
      else: {:error, :invalid_erasure_scope}
  end

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
