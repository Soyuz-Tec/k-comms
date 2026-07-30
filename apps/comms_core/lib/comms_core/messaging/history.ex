defmodule CommsCore.Messaging.History do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Messaging.{Message, MessageView, ReadModel}

  @max_history_page_limit 200
  @max_sender_label_refresh_message_ids 200

  defp authorize_conversation(:read_conversation, subject, resource),
    do: Conversations.authorize_read(value(resource, :id), subject)

  defp authorize_conversation(_action, _subject, _resource), do: {:error, :forbidden}

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
    |> ReadModel.hydrate_messages()
  end

  def list_history(conversation_id, subject, opts \\ []) do
    authorize = Keyword.get(opts, :authorize, &authorize_conversation/3)

    requested_after_sequence = integer(Keyword.get(opts, :after_sequence, 0), 0)

    with :ok <- authorize.(:read_conversation, subject, %{id: conversation_id}),
         {:ok, after_sequence} <-
           scoped_history_after_sequence(subject, requested_after_sequence) do
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

      {:ok, query |> Repo.all() |> ReadModel.hydrate_messages()}
    end
  end

  @doc """
  Returns one authorized durable history page and optional retained sender labels.

  Label IDs are derived only from the sliced, guest-history-clipped page. The
  IdentityAccess lookup is tenant-scoped and batched, so callers cannot use
  this operation as a directory enumeration surface.
  """
  @spec list_history_page(Ecto.UUID.t(), map(), keyword()) ::
          {:ok,
           %{
             messages: [MessageView.t()],
             sender_labels: [CommsCore.Accounts.RetainedSenderLabelView.t()],
             has_more: boolean(),
             next_after_sequence: non_neg_integer() | nil
           }}
          | {:error, term()}
  def list_history_page(conversation_id, subject, opts \\ [])
      when is_binary(conversation_id) and is_map(subject) and is_list(opts) do
    limit_count =
      clamp_limit(Keyword.get(opts, :limit, 100), @max_history_page_limit)

    history_opts =
      opts
      |> Keyword.delete(:include_sender_labels)
      |> Keyword.put(:limit, limit_count + 1)

    with {:ok, messages} <- list_history(conversation_id, subject, history_opts) do
      has_more = length(messages) > limit_count
      page = Enum.take(messages, limit_count)

      {:ok,
       %{
         messages: page,
         sender_labels: ReadModel.retained_sender_labels(page, subject, opts),
         has_more: has_more,
         next_after_sequence:
           page
           |> List.last()
           |> then(&if(&1, do: &1.conversation_sequence, else: nil))
       }}
    end
  end

  @doc """
  Refreshes retained labels for authors represented by an already-rendered
  message window.

  Caller-supplied message IDs are never used as identity IDs. The conversation
  read grant and, for guests, the admission history floor are applied first;
  authors are derived only from matching messages inside that authorized
  history scope before reaching IdentityAccess. Requests are unique and bounded
  to one label batch.
  """
  @spec refresh_sender_labels(Ecto.UUID.t(), [Ecto.UUID.t()], map()) ::
          {:ok, [CommsCore.Accounts.RetainedSenderLabelView.t()]}
          | {:error, :forbidden | :invalid_message_ids}
  def refresh_sender_labels(conversation_id, message_ids, subject)
      when is_binary(conversation_id) and is_list(message_ids) and is_map(subject) do
    with :ok <- Conversations.authorize_read(conversation_id, subject),
         :ok <- validate_sender_label_refresh_message_ids(message_ids),
         {:ok, after_sequence} <- scoped_history_after_sequence(subject, 0) do
      visible_sender_ids =
        Message
        |> where(
          [message],
          message.tenant_id == ^value(subject, :tenant_id) and
            message.conversation_id == ^conversation_id and
            message.conversation_sequence > ^after_sequence and
            message.id in ^message_ids
        )
        |> distinct(true)
        |> select([message], message.sender_user_id)
        |> Repo.all()

      {:ok,
       Accounts.resolve_retained_sender_labels(
         value(subject, :tenant_id),
         visible_sender_ids
       )}
    end
  end

  def refresh_sender_labels(_conversation_id, _message_ids, _subject),
    do: {:error, :invalid_message_ids}

  @doc """
  Checks whether a realtime message event is inside the caller's durable
  history scope.

  Realtime adapters use this when an event contains only a message identifier
  (for example, reaction events). The authoritative message row supplies the
  conversation sequence, so a guest can never infer or receive activity for a
  message created before their admission.
  """
  @spec message_event_visible?(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, boolean()} | {:error, :forbidden}
  def message_event_visible?(conversation_id, message_id, subject)
      when is_binary(conversation_id) and is_binary(message_id) and is_map(subject) do
    if valid_uuid?(conversation_id) and valid_uuid?(message_id) do
      with :ok <- Conversations.authorize_read(conversation_id, subject),
           {:ok, after_sequence} <- scoped_history_after_sequence(subject, 0) do
        visible? =
          Repo.exists?(
            from(message in Message,
              where:
                message.id == ^message_id and
                  message.tenant_id == ^value(subject, :tenant_id) and
                  message.conversation_id == ^conversation_id and
                  message.conversation_sequence > ^after_sequence
            )
          )

        {:ok, visible?}
      end
    else
      {:error, :forbidden}
    end
  end

  def message_event_visible?(_conversation_id, _message_id, _subject),
    do: {:error, :forbidden}

  @doc """
  Returns one authorized thread page and optional retained sender labels.

  Label IDs are derived only from the root and sliced reply page after
  conversation authorization. Callers cannot supply arbitrary identity IDs.
  """
  def get_thread(conversation_id, message_id, subject, opts \\ []) do
    target =
      Repo.get_by(Message,
        id: message_id,
        tenant_id: value(subject, :tenant_id),
        conversation_id: conversation_id
      )

    with %Message{} = target <- target,
         :ok <- Conversations.authorize_read(conversation_id, subject) do
      root_id = target.thread_root_message_id || target.id
      limit_count = clamp_limit(Keyword.get(opts, :limit, 50), 100)
      before_sequence = integer(Keyword.get(opts, :before_sequence), nil)

      root =
        Repo.get_by!(Message,
          id: root_id,
          tenant_id: value(subject, :tenant_id),
          conversation_id: conversation_id
        )
        |> ReadModel.hydrate_message()

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

      fetched = replies_query |> Repo.all() |> ReadModel.hydrate_messages()
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
         sender_labels: ReadModel.retained_sender_labels([root | replies], subject, opts),
         reply_count: root.thread_reply_count,
         has_more: has_more,
         next_before_sequence: next_before_sequence
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
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

  defp invalid_uuid?(value) do
    not (is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value)))
  end

  defp validate_sender_label_refresh_message_ids(message_ids) do
    if message_ids != [] and
         length(message_ids) <= @max_sender_label_refresh_message_ids and
         length(Enum.uniq(message_ids)) == length(message_ids) and
         Enum.all?(message_ids, &(not invalid_uuid?(&1))) do
      :ok
    else
      {:error, :invalid_message_ids}
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
  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  # Guest admission intentionally begins at the conversation sequence captured
  # when the link is redeemed. Enforce that floor in the data owner so every
  # adapter (REST and websocket replay) inherits the same no-prior-history rule.
  # A malformed guest subject fails closed instead of falling back to sequence 0.
  defp scoped_history_after_sequence(subject, requested_after_sequence) do
    case {value(subject, :account_type), value(subject, :guest_history_from_sequence)} do
      {account_type, history_from_sequence}
      when account_type in [:guest, "guest"] and is_integer(history_from_sequence) and
             history_from_sequence > 0 ->
        {:ok, max(requested_after_sequence, history_from_sequence - 1)}

      {account_type, _history_from_sequence} when account_type in [:guest, "guest"] ->
        {:error, :forbidden}

      _ ->
        {:ok, requested_after_sequence}
    end
  end
end
