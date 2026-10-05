defmodule CommsCore.Messaging.PersonalContent do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo, RuntimePorts}
  alias CommsCore.Messaging.{DraftView, Message, ReadModel}
  alias CommsCore.Messaging.PersonalContent.{Draft, SavedItem}
  @draft_ttl 30 * 24 * 60 * 60

  @doc false
  @spec rollback_rich_content_hazard_count() :: non_neg_integer()
  def rollback_rich_content_hazard_count() do
    # A false predicate still makes PostgreSQL validate every required owner
    # column without returning private content. Missing inventory is never zero.
    Repo.all(
      from(d in Draft,
        where: false,
        select:
          {d.id, d.tenant_id, d.user_id, d.conversation_id, d.thread_key, d.body, d.version,
           d.expires_at}
      )
    )

    Repo.all(
      from(s in SavedItem,
        where: false,
        select: {s.id, s.tenant_id, s.user_id, s.message_id, s.inserted_at}
      )
    )

    # Empty draft tombstones still contain user-private scope metadata. Expiry
    # and text scrubbing do not attest that this new erasure obligation ended.
    # Legacy Governance already erases message bodies/revisions and message-
    # owned attachments, including rich formatting and attachment-only messages.
    count = Repo.aggregate(Draft, :count, :id) + Repo.aggregate(SavedItem, :count, :id)

    if is_integer(count) and count >= 0,
      do: count,
      else: raise("Invalid messaging rollback count")
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      raise "ConversationContent rich rollback inventory unavailable"
  end

  def saved_items(subject, params) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, cursor} <- saved_cursor(value(params, :cursor)) do
      authorization = Conversations.active_membership_authorization_query(grant)
      limit = bounded(value(params, :limit), 30, 100)

      rows =
        from(s in SavedItem,
          join: m in Message,
          on: s.message_id == m.id and s.tenant_id == m.tenant_id,
          join: a in subquery(authorization),
          on: a.conversation_id == m.conversation_id,
          where:
            s.tenant_id == ^grant.tenant_id and s.user_id == ^grant.user_id and
              m.status == :active,
          order_by: [desc: s.inserted_at, desc: s.id],
          limit: ^(limit + 1),
          select: %{message: m, inserted_at: s.inserted_at, id: s.id}
        )
        |> after_saved_cursor(cursor)
        |> Repo.all()

      {:ok,
       %{
         messages:
           rows |> Enum.take(limit) |> Enum.map(& &1.message) |> ReadModel.hydrate_messages(),
         truncated: length(rows) > limit,
         has_more: length(rows) > limit,
         next_cursor:
           if(length(rows) > limit, do: encode_saved_cursor(Enum.at(rows, limit - 1)), else: nil)
       }}
    end
  end

  def save_message(message_id, subject) do
    with {:ok, message_id} <- uuid(message_id),
         {:ok, grant} <- Accounts.access_grant(subject),
         conversation_id when is_binary(conversation_id) <-
           Repo.one(
             from(m in Message,
               where:
                 m.id == ^message_id and m.tenant_id == ^grant.tenant_id and m.status == :active,
               select: m.conversation_id
             )
           ) do
      write_transaction(subject, conversation_id, :read, fn grant ->
        message =
          Repo.one(
            from(m in Message,
              where:
                m.id == ^message_id and m.tenant_id == ^grant.tenant_id and m.status == :active,
              lock: "FOR SHARE"
            )
          ) || Repo.rollback(:not_found)

        case Conversations.authorize_read(message.conversation_id, subject) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        count =
          Repo.aggregate(
            from(s in SavedItem,
              where: s.tenant_id == ^grant.tenant_id and s.user_id == ^grant.user_id
            ),
            :count
          )

        existing =
          Repo.get_by(SavedItem,
            tenant_id: grant.tenant_id,
            user_id: grant.user_id,
            message_id: message_id
          )

        if count >= 500 and is_nil(existing), do: Repo.rollback(:saved_item_capacity)

        %SavedItem{}
        |> Ecto.Changeset.change(%{
          tenant_id: grant.tenant_id,
          user_id: grant.user_id,
          message_id: message_id
        })
        |> Repo.insert!(
          on_conflict: :nothing,
          conflict_target: [:tenant_id, :user_id, :message_id]
        )

        %{message_id: message_id, saved: true}
      end)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def unsave_message(message_id, subject) do
    with {:ok, message_id} <- uuid(message_id),
         {:ok, _grant} <- Accounts.access_grant(subject) do
      write_transaction(subject, nil, nil, fn grant ->
        Repo.delete_all(
          from(s in SavedItem,
            where:
              s.tenant_id == ^grant.tenant_id and s.user_id == ^grant.user_id and
                s.message_id == ^message_id
          )
        )

        %{message_id: message_id, saved: false}
      end)
    end
  end

  def get_draft(conversation_id, params, subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         :ok <- Conversations.authorize_read(conversation_id, subject),
         {:ok, key} <- thread_key(value(params, :thread_key), conversation_id, grant.tenant_id) do
      draft =
        Repo.get_by(Draft,
          tenant_id: grant.tenant_id,
          user_id: grant.user_id,
          conversation_id: conversation_id,
          thread_key: key
        )

      {:ok, draft_view(draft, conversation_id, key)}
    end
  end

  def put_draft(conversation_id, attrs, subject) do
    body = value(attrs, :body)
    expected = value(attrs, :expected_version)

    with {:ok, grant} <- Accounts.access_grant(subject),
         :ok <- Conversations.authorize_send_message(conversation_id, subject),
         {:ok, key} <- thread_key(value(attrs, :thread_key), conversation_id, grant.tenant_id),
         true <- (is_binary(body) and String.length(body) <= 65_535) || {:error, :invalid_draft},
         true <- (is_integer(expected) and expected >= 0) || {:error, :invalid_draft} do
      write_transaction(subject, conversation_id, :send, fn grant ->
        case Conversations.authorize_send_message(conversation_id, subject) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        case thread_key(value(attrs, :thread_key), conversation_id, grant.tenant_id) do
          {:ok, ^key} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        draft =
          Repo.get_by(Draft,
            tenant_id: grant.tenant_id,
            user_id: grant.user_id,
            conversation_id: conversation_id,
            thread_key: key
          )

        if is_nil(draft) and
             Repo.aggregate(
               from(d in Draft,
                 where: d.tenant_id == ^grant.tenant_id and d.user_id == ^grant.user_id
               ),
               :count
             ) >= 500,
           do: Repo.rollback(:draft_capacity)

        version = if draft, do: draft.version, else: 0
        if expected != version, do: Repo.rollback(:stale_draft)
        # Keep the empty tombstone so an old device cannot recreate text after a successful clear.
        (draft || %Draft{})
        |> Ecto.Changeset.change(%{
          tenant_id: grant.tenant_id,
          user_id: grant.user_id,
          conversation_id: conversation_id,
          thread_key: key,
          body: body,
          version: version + 1,
          expires_at:
            DateTime.add(DateTime.utc_now(), @draft_ttl, :second)
            |> DateTime.truncate(:microsecond)
        })
        |> Repo.insert_or_update!()
        |> draft_view(conversation_id, key)
      end)
    end
  end

  def prune_expired_drafts(caller) do
    if RuntimePorts.authorized_job_worker?(:personal_content_cleanup, caller) do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        ids =
          Repo.all(
            from(d in Draft,
              where: d.expires_at <= ^now and d.body != "",
              order_by: [asc: d.expires_at],
              select: d.id,
              limit: 1_000,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        {count, _} =
          Repo.update_all(from(d in Draft, where: d.id in ^ids),
            set: [body: "", updated_at: now],
            inc: [version: 1]
          )

        %{drafts_scrubbed: count}
      end)
    else
      {:error, :forbidden}
    end
  end

  def erase(tenant_id, type, target_id) when type in [:user, :conversation] do
    if Repo.in_transaction?() do
      # User erasure and every private write retain exactly the same owner
      # advisory. Conversation erasure retains its archived parent upstream.
      if type == :user, do: lock_user!(tenant_id, target_id)
      draft_query = from(d in Draft, where: d.tenant_id == ^tenant_id)

      draft_query =
        if type == :user,
          do: where(draft_query, [d], d.user_id == ^target_id),
          else: where(draft_query, [d], d.conversation_id == ^target_id)

      Repo.delete_all(draft_query)

      if type == :user,
        do:
          Repo.delete_all(
            from(s in SavedItem, where: s.tenant_id == ^tenant_id and s.user_id == ^target_id)
          )

      :ok
    else
      {:error, :transaction_required}
    end
  end

  defp thread_key(nil, _conversation_id, _tenant_id), do: {:ok, "main"}
  defp thread_key("main", _conversation_id, _tenant_id), do: {:ok, "main"}

  defp thread_key(value, conversation_id, tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(value),
         %Message{thread_root_message_id: nil} <-
           Repo.get_by(Message,
             id: id,
             tenant_id: tenant_id,
             conversation_id: conversation_id,
             status: :active
           ) do
      {:ok, id}
    else
      _ -> {:error, :invalid_reply_target}
    end
  end

  defp draft_view(nil, conversation_id, key),
    do: %DraftView{conversation_id: conversation_id, thread_key: key, body: "", version: 0}

  defp draft_view(d, conversation_id, key) do
    body = if DateTime.compare(d.expires_at, DateTime.utc_now()) == :gt, do: d.body, else: ""

    %DraftView{
      conversation_id: conversation_id,
      thread_key: key,
      body: body,
      version: d.version,
      expires_at: d.expires_at
    }
  end

  defp saved_cursor(nil), do: {:ok, nil}
  defp saved_cursor(""), do: {:ok, nil}

  defp saved_cursor(value) when is_binary(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, %{"v" => 1, "id" => id, "at" => at}} <- Jason.decode(json),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, at, _} <- DateTime.from_iso8601(at) do
      {:ok, {at, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp saved_cursor(_), do: {:error, :invalid_cursor}
  defp after_saved_cursor(query, nil), do: query

  defp after_saved_cursor(query, {at, id}),
    do: where(query, [s, _m, _a], s.inserted_at < ^at or (s.inserted_at == ^at and s.id < ^id))

  defp encode_saved_cursor(row),
    do:
      %{v: 1, id: row.id, at: DateTime.to_iso8601(row.inserted_at)}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp write_transaction(subject, conversation_id, mode, operation) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Repo.transaction(
      fn ->
        budget!(deadline)

        grant =
          case Accounts.lock_content_write_grant(subject, deadline) do
            {:ok, grant} -> grant
            {:error, reason} -> Repo.rollback(reason)
          end

        if conversation_id do
          budget!(deadline)

          case Conversations.lock_call_conversation(grant.tenant_id, conversation_id, :share) do
            {:ok, _conversation} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        current_grant!(subject, deadline)
        budget!(deadline)
        lock_user!(grant.tenant_id, grant.user_id)
        current_grant!(subject, deadline)
        authorize!(mode, conversation_id, subject)
        result = operation.(grant)
        current_grant!(subject, deadline)
        authorize!(mode, conversation_id, subject)
        budget!(deadline)
        result
      end,
      timeout: 20_000
    )
  end

  defp authorize!(nil, nil, _subject), do: :ok

  defp authorize!(:read, conversation_id, subject) do
    case Conversations.authorize_read(conversation_id, subject) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize!(:send, conversation_id, subject) do
    case Conversations.authorize_send_message(conversation_id, subject) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp current_grant!(subject, deadline) do
    budget!(deadline)

    case Accounts.access_grant(subject) do
      {:ok, grant} -> grant
      {:error, reason} -> Repo.rollback(reason)
    end

    budget!(deadline)
  end

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)
    :ok
  end

  defp lock_user!(tenant_id, user_id) do
    lock_key = "personal-content:" <> tenant_id <> ":" <> user_id

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      [lock_key]
    )

    :ok
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp bounded(v, fallback, maximum) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> bounded(n, fallback, maximum)
      _ -> fallback
    end
  end

  defp bounded(v, _fallback, maximum) when is_integer(v), do: v |> max(1) |> min(maximum)
  defp bounded(_, fallback, _maximum), do: fallback
end
