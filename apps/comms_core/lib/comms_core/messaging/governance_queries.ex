defmodule CommsCore.Messaging.GovernanceQueries do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo

  alias CommsCore.Messaging.{
    GovernanceImpact,
    Message,
    MessageRevision,
    Reaction,
    RetentionCandidate,
    RetentionScope
  }

  def governance_impact(tenant_id, target_type, target_id)
      when is_binary(tenant_id) and target_type in [:user, :conversation, :message] and
             is_binary(target_id) do
    if valid_uuid?(tenant_id) and valid_uuid?(target_id) do
      rows =
        Message
        |> where([message], message.tenant_id == ^tenant_id)
        |> governance_target(target_type, target_id)
        |> select(
          [message],
          {message.id, message.conversation_id, message.sender_user_id}
        )
        |> Repo.all()

      %GovernanceImpact{
        found?: rows != [],
        message_ids: sorted_unique(rows, 0),
        conversation_ids: sorted_unique(rows, 1),
        user_ids: sorted_unique(rows, 2)
      }
    else
      empty_governance_impact()
    end
  end

  @doc """
  Selects undeleted messages that are older than their conversation cutoff.

  Ordering and limiting are applied once across every supplied scope so a scan
  always returns the globally oldest candidates first. Persistence schemas do
  not cross the boundary.
  """
  @spec retention_candidates(
          String.t(),
          [RetentionScope.t()],
          [String.t()],
          pos_integer()
        ) :: [RetentionCandidate.t()]
  def retention_candidates(tenant_id, scopes, excluded_message_ids, limit_count)
      when is_binary(tenant_id) and is_list(scopes) and is_list(excluded_message_ids) and
             is_integer(limit_count) and limit_count > 0 do
    with true <- valid_uuid?(tenant_id),
         true <- Enum.all?(excluded_message_ids, &valid_uuid?/1),
         {:ok, scope_filter} <- retention_scope_filter(scopes) do
      Message
      |> where(
        [message],
        message.tenant_id == ^tenant_id and message.status != :deleted and
          message.id not in ^Enum.uniq(excluded_message_ids)
      )
      |> where(^scope_filter)
      |> order_by([message], asc: message.inserted_at, asc: message.id)
      |> limit(^limit_count)
      |> select([message], {message.id, message.conversation_id})
      |> Repo.all()
      |> Enum.map(fn {message_id, conversation_id} ->
        %RetentionCandidate{
          message_id: message_id,
          conversation_id: conversation_id
        }
      end)
    else
      _invalid_scope -> []
    end
  end

  def retention_candidates(_tenant_id, _scopes, _excluded_message_ids, _limit_count), do: []

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

  defp governance_target(query, :user, target_id),
    do: where(query, [message], message.sender_user_id == ^target_id)

  defp governance_target(query, :conversation, target_id),
    do: where(query, [message], message.conversation_id == ^target_id)

  defp governance_target(query, :message, target_id),
    do: where(query, [message], message.id == ^target_id)

  defp sorted_unique(rows, element_index) do
    rows
    |> Enum.map(&elem(&1, element_index))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp empty_governance_impact do
    %GovernanceImpact{
      found?: false,
      message_ids: [],
      conversation_ids: [],
      user_ids: []
    }
  end

  defp retention_scope_filter(scopes) do
    with {:ok, scopes_by_cutoff} <- group_retention_scopes(scopes) do
      scope_filter =
        Enum.reduce(scopes_by_cutoff, dynamic(false), fn {cutoff_at, conversation_ids},
                                                         scope_filter ->
          dynamic(
            [message],
            ^scope_filter or
              (message.conversation_id in ^conversation_ids and
                 message.inserted_at < ^cutoff_at)
          )
        end)

      {:ok, scope_filter}
    end
  end

  defp group_retention_scopes(scopes) do
    scopes
    |> Enum.reduce_while({:ok, %{}}, fn
      %RetentionScope{conversation_id: conversation_id, cutoff_at: %DateTime{} = cutoff_at},
      {:ok, grouped}
      when is_binary(conversation_id) ->
        if valid_uuid?(conversation_id) do
          {:cont,
           {:ok, Map.update(grouped, cutoff_at, [conversation_id], &[conversation_id | &1])}}
        else
          {:halt, :error}
        end

      _scope, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, grouped} ->
        grouped =
          grouped
          |> Enum.map(fn {cutoff_at, conversation_ids} ->
            {cutoff_at, conversation_ids |> Enum.uniq() |> Enum.sort()}
          end)
          |> Enum.sort_by(fn {cutoff_at, _conversation_ids} ->
            DateTime.to_unix(cutoff_at, :microsecond)
          end)

        {:ok, grouped}

      :error ->
        :error
    end
  end

  defp validate_erasure_scope(tenant_id, ids) do
    if valid_uuid?(tenant_id) and Enum.all?(ids, &valid_uuid?/1),
      do: :ok,
      else: {:error, :invalid_erasure_scope}
  end

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
