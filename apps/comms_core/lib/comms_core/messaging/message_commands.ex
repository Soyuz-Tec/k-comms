defmodule CommsCore.Messaging.MessageCommands do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Administration, Attachments, Conversations, Outbox, Repo}
  alias CommsCore.Audit
  alias CommsCore.Conversations.MessageWriteSlot

  alias CommsCore.Messaging.{
    Message,
    MessageDeletionCandidate,
    MessageMetadata,
    MessageMention,
    MessageRevision,
    ReadModel
  }

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
    authorize = Keyword.get(opts, :authorize, &authorize_conversation/3)

    with :ok <- validate_identity(attrs, subject),
         :ok <- validate(attrs) do
      case Repo.transaction(fn -> accept_in_transaction(attrs, subject, authorize) end) do
        {:ok, {message, status}} -> {:ok, message, status}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def edit_message(message_id, body, subject) when is_binary(body) do
    body = String.trim(body)

    with :ok <- validate_body(body) do
      Repo.transaction(fn ->
        message = locked_message(message_id, subject)

        case authorize_edit(message, subject) do
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

            ReadModel.hydrate_message(updated)

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
           :ok <- authorize_delete(message, subject),
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

        {:ok, ReadModel.hydrate_message(updated)}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    else
      {:error, :transaction_required}
    end
  end

  def delete_message(_message_id, _subject, _policy_check), do: {:error, :not_found}

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
      :ok -> {ReadModel.hydrate_message(message), :duplicate}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_conversation(:send_message, subject, resource),
    do: Conversations.authorize_send_message(value(resource, :id), subject)

  defp authorize_conversation(:read_conversation, subject, resource),
    do: Conversations.authorize_read(value(resource, :id), subject)

  defp authorize_conversation(_action, _subject, _resource), do: {:error, :forbidden}

  defp authorize_edit(%Message{} = message, subject) do
    with :ok <- Conversations.authorize_send_message(message.conversation_id, subject),
         true <- same_tenant?(message, subject),
         true <- value(subject, :user_id) == message.sender_user_id,
         true <- message.status == :active,
         {:ok,
          %Administration.ConversationContentPolicy{
            message_edit_window_seconds: edit_window_seconds
          }} <- Administration.conversation_content_policy(subject),
         :ok <- enforce_edit_window(message, edit_window_seconds) do
      :ok
    else
      {:error, :edit_window_expired} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_delete(%Message{} = message, subject) do
    with :ok <- Conversations.authorize_read(message.conversation_id, subject),
         true <- same_tenant?(message, subject) do
      if value(subject, :user_id) == message.sender_user_id do
        :ok
      else
        Conversations.authorize_manage(message.conversation_id, subject)
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  defp same_tenant?(%Message{tenant_id: tenant_id}, subject),
    do: tenant_id == value(subject, :tenant_id)

  defp enforce_edit_window(%Message{} = message, seconds)
       when is_integer(seconds) and seconds > 0 do
    if DateTime.compare(message.inserted_at, DateTime.add(now(), -seconds, :second)) != :lt,
      do: :ok,
      else: {:error, :edit_window_expired}
  end

  defp enforce_edit_window(_message, _seconds), do: {:error, :edit_window_expired}

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

    ReadModel.hydrate_message(message)
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
        MessageMetadata.validate(attrs.metadata)
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

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
