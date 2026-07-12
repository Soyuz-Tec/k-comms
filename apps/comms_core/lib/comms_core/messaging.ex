defmodule CommsCore.Messaging do
  import Ecto.Query

  alias CommsCore.{Attachments, Authorization, Outbox, Repo}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.Conversation
  alias CommsCore.Messaging.{Message, MessageRevision, Reaction}

  @max_metadata_bytes 65_536
  @required [:tenant_id, :conversation_id, :sender_user_id, :sender_device_id, :client_message_id]

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
    |> preload([:attachments, :reactions])
    |> Repo.all()
  end

  def list_history(conversation_id, subject, opts \\ []) do
    with :ok <- Authorization.authorize(:read_conversation, subject, %{id: conversation_id}) do
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
        |> preload([:attachments, :reactions])

      {:ok, Repo.all(query)}
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

            Repo.preload(updated, [:attachments, :reactions])

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  def edit_message(_, _, _), do: {:error, :invalid_message_body}

  def delete_message(message_id, subject) do
    Repo.transaction(fn ->
      message = locked_message(message_id, subject)

      case Authorization.authorize(:delete_message, subject, message) do
        :ok ->
          updated =
            message
            |> Message.delete_changeset(%{body: nil, status: :deleted, deleted_at: now()})
            |> Repo.update!()

          insert_event(updated, "message.deleted.v1", subject, %{
            conversation_sequence: updated.conversation_sequence
          })

          Repo.preload(updated, [:attachments, :reactions])

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

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
        {:ok, reaction} -> {:ok, reaction}
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
    query_text = String.trim(query_text)

    if query_text == "" do
      {:ok, []}
    else
      limit_count = clamp_limit(Keyword.get(opts, :limit, 50))

      query =
        from(m in Message,
          join: membership in CommsCore.Conversations.Membership,
          on: membership.conversation_id == m.conversation_id,
          where:
            m.tenant_id == ^value(subject, :tenant_id) and
              membership.tenant_id == ^value(subject, :tenant_id) and
              membership.user_id == ^value(subject, :user_id) and
              is_nil(membership.left_at) and m.status == :active and
              fragment(
                "to_tsvector('simple', coalesce(?, '')) @@ plainto_tsquery('simple', ?)",
                m.body,
                ^query_text
              ),
          order_by: [desc: m.inserted_at],
          limit: ^limit_count,
          preload: [:attachments, :reactions]
        )

      {:ok, Repo.all(query)}
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
    conversation =
      Repo.get_by(Conversation,
        id: message.conversation_id,
        tenant_id: message.tenant_id
      ) || Repo.rollback(:conversation_not_found)

    case authorize.(:send_message, subject, conversation) do
      :ok -> {Repo.preload(message, [:attachments, :reactions]), :duplicate}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

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
    conversation =
      Repo.one(
        from(c in Conversation,
          where: c.id == ^attrs.conversation_id and c.tenant_id == ^attrs.tenant_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:conversation_not_found)

    with :ok <- authorize.(:send_message, subject, conversation),
         :ok <- validate_reply(attrs, conversation) do
      persist(attrs, subject, conversation)
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

  defp persist(attrs, subject, conversation) do
    sequence = conversation.next_sequence

    conversation
    |> Conversation.changeset(%{next_sequence: sequence + 1})
    |> Repo.update!()

    message =
      %Message{}
      |> Message.changeset(Map.merge(attrs, %{conversation_sequence: sequence, status: :active}))
      |> Repo.insert!()

    :ok = Attachments.attach_ready(attrs.attachment_ids, message, subject)

    insert_event(message, "message.created.v1", subject, %{
      conversation_sequence: sequence,
      sender_user_id: message.sender_user_id,
      reply_to_message_id: message.reply_to_message_id,
      body: message.body
    })

    Repo.preload(message, [:attachments, :reactions])
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

    %AuditEvent{}
    |> AuditEvent.changeset(%{
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
    |> Repo.insert!()
  end

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

  defp validate_reply(%{reply_to_message_id: nil}, _), do: :ok

  defp validate_reply(attrs, conversation) do
    case Repo.get_by(Message,
           id: attrs.reply_to_message_id,
           tenant_id: conversation.tenant_id,
           conversation_id: conversation.id
         ) do
      %Message{} -> :ok
      nil -> {:error, :invalid_reply_target}
    end
  end

  defp normalize(attrs) do
    keys = [
      :tenant_id,
      :conversation_id,
      :sender_user_id,
      :sender_device_id,
      :reply_to_message_id,
      :client_message_id,
      :body,
      :metadata,
      :attachment_ids
    ]

    normalized =
      Map.new(keys, fn key ->
        {key, Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))}
      end)

    normalized
    |> Map.update(:body, nil, fn body -> if is_binary(body), do: String.trim(body), else: body end)
    |> Map.update(:metadata, %{}, fn value -> if is_map(value), do: value, else: %{} end)
    |> Map.update(:attachment_ids, [], fn value -> if is_list(value), do: value, else: [] end)
  end

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, value) do
    case integer(value, nil) do
      nil -> query
      sequence -> where(query, [m], m.conversation_sequence < ^sequence)
    end
  end

  defp validate_body(body) when not is_binary(body), do: {:error, :message_body_required}

  defp validate_body(body) do
    cond do
      body == "" -> {:error, :message_body_required}
      String.length(body) > 65_535 -> {:error, :message_too_large}
      true -> :ok
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
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
