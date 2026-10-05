defmodule CommsCore.Whiteboards.Library do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Conversations, Repo}

  alias CommsCore.Whiteboards.{
    Asset,
    AssetView,
    BoardView,
    Commands,
    Operation,
    Payload,
    Scene,
    Snapshot,
    Snapshots,
    Version,
    VersionView,
    Whiteboard
  }

  @doc false
  @spec rollback_rich_content_hazard_count() :: non_neg_integer()
  def rollback_rich_content_hazard_count() do
    # Validate owned storage and required columns without retrieving content.
    Repo.all(
      from(b in Whiteboard,
        where: false,
        select:
          {b.id, b.tenant_id, b.conversation_id, b.title, b.title_actor_user_id,
           b.library_version}
      )
    )

    Repo.all(
      from(v in Version,
        where: false,
        select:
          {v.id, v.tenant_id, v.whiteboard_id, v.actor_user_id, v.label, v.elements,
           v.source_actor_user_ids}
      )
    )

    Repo.all(
      from(a in Asset,
        where: false,
        select:
          {a.id, a.tenant_id, a.whiteboard_id, a.actor_user_id, a.attachment_id,
           a.source_message_id}
      )
    )

    Repo.all(
      from(o in Operation,
        where: false,
        select:
          {o.id, o.tenant_id, o.whiteboard_id, o.actor_user_id, o.kind, o.payload, o.sequence,
           o.source_actor_user_ids}
      )
    )

    Repo.all(
      from(s in Snapshot,
        where: false,
        select:
          {s.id, s.tenant_id, s.whiteboard_id, s.elements, s.generation_sequence,
           s.through_sequence}
      )
    )

    restored =
      from(o in Operation,
        where:
          o.kind == "scene.update" and
            fragment("cardinality(?) > 0", o.source_actor_user_ids) and
            fragment("(? -> 'elements') IS DISTINCT FROM '[]'::jsonb", o.payload)
      )

    dependent =
      from(s in Snapshot,
        join: o in subquery(restored),
        on:
          o.tenant_id == s.tenant_id and o.whiteboard_id == s.whiteboard_id and
            o.sequence >= s.generation_sequence and o.sequence <= s.through_sequence,
        where: fragment("(? -> 'elements') IS DISTINCT FROM '[]'::jsonb", s.elements),
        select: s.id,
        distinct: true
      )

    # Existing ordinary board logs/snapshots are governed by the legacy owner.
    # Titles, checkpoints, image bindings and retained restore provenance are new.
    counts = [
      Repo.aggregate(Version, :count, :id),
      Repo.aggregate(Asset, :count, :id),
      Repo.aggregate(
        from(b in Whiteboard,
          where: not is_nil(b.title_actor_user_id) or b.title != "Untitled board"
        ),
        :count,
        :id
      ),
      Repo.aggregate(restored, :count, :id),
      Repo.aggregate(subquery(dependent), :count, :id)
    ]

    if Enum.all?(counts, &(is_integer(&1) and &1 >= 0)),
      do: Enum.sum(counts),
      else: raise("Invalid whiteboard rollback count")
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      raise "Collaboration rich rollback inventory unavailable"
  end

  def gallery(subject, params) do
    with {:ok, ids} <- Conversations.active_conversation_ids(subject) do
      requested = value(params, :conversation_id)

      ids =
        if is_binary(requested) and requested != "",
          do: Enum.filter(ids, &(&1 == requested)),
          else: ids

      limit = bounded(value(params, :limit), 30, 100)
      query = trimmed(value(params, :q))

      if String.length(query) > 160 do
        {:error, :invalid_search_query}
      else
        rows =
          from(b in Whiteboard,
            where: b.tenant_id == ^value(subject, :tenant_id) and b.conversation_id in ^ids,
            order_by: [desc: b.updated_at, desc: b.id],
            limit: ^(limit + 1)
          )
          |> title_filter(query)
          |> Repo.all()

        {:ok,
         %{
           boards: Enum.map(Enum.take(rows, limit), &board_view/1),
           truncated: length(rows) > limit
         }}
      end
    end
  end

  def rename(conversation_id, attrs, subject) do
    title = trimmed(value(attrs, :title))
    expected = value(attrs, :expected_version)

    with true <- String.length(title) in 1..160 || {:error, :invalid_board_title},
         :ok <- Conversations.authorize_manage(conversation_id, subject) do
      write_transaction(conversation_id, subject, :manage, fn deadline ->
        Commands.write_budget!(deadline)
        %Whiteboard{} = board = lock_board!(conversation_id, subject)
        Commands.current_write_authority!(conversation_id, subject, deadline, :manage)
        if board.library_version != expected, do: Repo.rollback(:stale_board_version)
        :ok = authorized_manage!(conversation_id, subject)

        changeset =
          Ecto.Changeset.change(board,
            title: title,
            title_actor_user_id: value(subject, :user_id),
            library_version: board.library_version + 1
          )

        Repo.update!(changeset) |> board_view()
      end)
    end
  end

  def versions(conversation_id, subject) do
    with :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      rows =
        from(v in Version,
          where:
            v.tenant_id == ^value(subject, :tenant_id) and v.conversation_id == ^conversation_id,
          order_by: [desc: v.inserted_at, desc: v.id],
          limit: 100
        )
        |> Repo.all()

      {:ok, Enum.map(rows, &version_view/1)}
    end
  end

  def checkpoint(conversation_id, attrs, subject) do
    label = trimmed(value(attrs, :label))

    with true <- String.length(label) in 1..160 || {:error, :invalid_board_title},
         :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      write_transaction(conversation_id, subject, :use, fn deadline ->
        Commands.write_budget!(deadline)
        %Whiteboard{} = board = lock_board!(conversation_id, subject)
        Commands.current_write_authority!(conversation_id, subject, deadline, :use)

        case Conversations.authorize_use_whiteboard(conversation_id, subject) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        if board.sequence != value(attrs, :expected_sequence),
          do: Repo.rollback(:stale_board_version)

        count = Repo.aggregate(from(v in Version, where: v.whiteboard_id == ^board.id), :count)
        if count >= 100, do: Repo.rollback(:whiteboard_version_capacity)
        elements = scene!(board)
        Commands.current_write_authority!(conversation_id, subject, deadline, :use)

        %Version{}
        |> Ecto.Changeset.change(%{
          tenant_id: board.tenant_id,
          whiteboard_id: board.id,
          conversation_id: board.conversation_id,
          actor_user_id: value(subject, :user_id),
          label: label,
          through_sequence: board.sequence,
          elements: %{"elements" => elements},
          source_actor_user_ids: scene_authors!(board)
        })
        |> Repo.insert!()
        |> version_view()
      end)
    end
  end

  def restore(conversation_id, version_id, attrs, subject) do
    with {:ok, version_id} <- uuid(version_id),
         :ok <- Conversations.authorize_manage(conversation_id, subject) do
      write_transaction(conversation_id, subject, :manage, fn deadline ->
        Commands.write_budget!(deadline)
        %Whiteboard{} = board = lock_board!(conversation_id, subject)
        Commands.current_write_authority!(conversation_id, subject, deadline, :manage)
        :ok = authorized_manage!(conversation_id, subject)

        if board.sequence != value(attrs, :expected_sequence),
          do: Repo.rollback(:stale_board_version)

        version =
          Repo.get_by(Version,
            id: version_id,
            tenant_id: board.tenant_id,
            whiteboard_id: board.id
          ) || Repo.rollback(:not_found)

        elements = version.elements["elements"] || []

        # Every source remains live and approved at restore time. Erased assets cannot be resurrected by a checkpoint.
        :ok = approved_elements!(board, elements, subject)

        {:ok, clear, :created} =
          Commands.append(
            conversation_id,
            %{
              client_operation_id: "restore-clear-" <> Ecto.UUID.generate(),
              kind: "board.clear",
              payload: %{}
            },
            subject,
            deadline
          )

        Payload.chunk_elements(elements)
        |> Enum.reduce(clear.sequence, fn chunk, _sequence ->
          case Commands.append_restored(
                 conversation_id,
                 %{
                   client_operation_id: "restore-scene-" <> Ecto.UUID.generate(),
                   kind: "scene.update",
                   base_sequence: clear.sequence,
                   payload: %{"elements" => chunk}
                 },
                 subject,
                 version,
                 deadline
               ) do
            {:ok, operation, :created} -> operation.sequence
            {:error, reason} -> Repo.rollback(reason)
          end

          # Append owns the sequence; this value is used only for the response below.
        end)

        board_view(Repo.get!(Whiteboard, board.id))
      end)
    end
  end

  def export(conversation_id, subject) do
    with :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      write_transaction(conversation_id, subject, :use, fn deadline ->
        Commands.write_budget!(deadline)
        %Whiteboard{} = board = lock_board!(conversation_id, subject)
        Commands.current_write_authority!(conversation_id, subject, deadline, :use)

        case Conversations.authorize_use_whiteboard(conversation_id, subject) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        elements = scene!(board)
        :ok = approved_elements!(board, elements, subject)

        %{
          type: "excalidraw",
          version: 2,
          source: "K-Comms",
          title: board.title,
          library_version: board.library_version,
          through_sequence: board.sequence,
          elements: elements,
          files: %{},
          assets: asset_views!(board, subject)
        }
      end)
    end
  end

  def add_asset(conversation_id, attachment_id, subject) do
    with {:ok, attachment_id} <- Ecto.UUID.cast(attachment_id),
         :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      write_transaction(conversation_id, subject, :use, fn deadline ->
        Commands.write_budget!(deadline)
        %Whiteboard{} = board = lock_board!(conversation_id, subject)
        Commands.current_write_authority!(conversation_id, subject, deadline, :use)

        if Repo.aggregate(from(a in Asset, where: a.whiteboard_id == ^board.id), :count) >= 100,
          do: Repo.rollback(:whiteboard_asset_capacity)

        receipt =
          case CommsCore.Whiteboards.BoardAssetPort.claim(attachment_id, conversation_id, subject) do
            {:ok, receipt} -> receipt
            {:error, reason} -> Repo.rollback(reason)
          end

        Commands.current_write_authority!(conversation_id, subject, deadline, :use)

        asset =
          Repo.get_by(Asset, whiteboard_id: board.id, attachment_id: attachment_id) ||
            %Asset{}
            |> Ecto.Changeset.change(%{
              tenant_id: board.tenant_id,
              whiteboard_id: board.id,
              conversation_id: conversation_id,
              attachment_id: receipt.attachment_id,
              source_message_id: receipt.source_message_id,
              actor_user_id: value(subject, :user_id)
            })
            |> Repo.insert!()

        asset_view(asset, receipt)
      end)
    else
      :error -> {:error, :asset_unavailable}
      {:error, _} = error -> error
    end
  end

  def asset_download(conversation_id, asset_id, subject) do
    with {:ok, asset_id} <- uuid(asset_id),
         :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject),
         %Asset{} = asset <-
           Repo.get_by(Asset,
             id: asset_id,
             tenant_id: value(subject, :tenant_id),
             conversation_id: conversation_id
           ),
         {:ok, receipt} <-
           CommsCore.Whiteboards.BoardAssetPort.read(
             asset.attachment_id,
             asset.source_message_id,
             conversation_id,
             subject
           ) do
      {:ok, receipt}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp approved_elements!(board, elements, subject) do
    case CommsCore.Whiteboards.AssetValidation.validate(board, elements, subject) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp write_transaction(conversation_id, subject, permission, operation) do
    deadline = Commands.write_deadline()

    Repo.transaction(
      fn ->
        Commands.lock_write_authority!(conversation_id, subject, deadline)
        Commands.current_write_authority!(conversation_id, subject, deadline, permission)
        result = operation.(deadline)
        Commands.current_write_authority!(conversation_id, subject, deadline, permission)
        result
      end,
      timeout: 20_000
    )
  end

  defp asset_views!(board, subject) do
    from(a in Asset, where: a.whiteboard_id == ^board.id)
    |> Repo.all()
    |> Enum.flat_map(fn asset ->
      case CommsCore.Whiteboards.BoardAssetPort.read(
             asset.attachment_id,
             asset.source_message_id,
             board.conversation_id,
             subject
           ) do
        {:ok, receipt} -> [asset_view(asset, receipt)]
        {:error, _} -> []
      end
    end)
  end

  defp scene!(board) do
    generation =
      Repo.one(
        from(o in Operation,
          where: o.whiteboard_id == ^board.id and o.kind == "board.clear",
          select: max(o.sequence)
        )
      ) || 0

    {base_elements, after_sequence} =
      case Snapshots.current(board.id) do
        %Snapshot{through_sequence: through} = snapshot when through <= board.sequence ->
          {Snapshots.elements(snapshot), through}

        _ ->
          {[], generation}
      end

    initial =
      case Scene.new(base_elements) do
        {:ok, scene} -> scene
        {:error, reason} -> Repo.rollback(reason)
      end

    scene =
      from(o in Operation,
        where:
          o.whiteboard_id == ^board.id and o.sequence > ^after_sequence and
            o.sequence <= ^board.sequence,
        order_by: [asc: o.sequence]
      )
      |> Repo.stream(max_rows: 20)
      |> Enum.reduce(initial, fn op, scene ->
        case Scene.merge(scene, op.payload["elements"] || []) do
          {:ok, next} -> next
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    Scene.elements(scene)
  end

  defp scene_authors!(board) do
    generation =
      Repo.one(
        from(o in Operation,
          where: o.whiteboard_id == ^board.id and o.kind == "board.clear",
          select: max(o.sequence)
        )
      ) || 0

    from(o in Operation,
      where:
        o.whiteboard_id == ^board.id and o.sequence > ^generation and
          o.sequence <= ^board.sequence and o.kind == "scene.update",
      select: {o.actor_user_id, o.source_actor_user_ids}
    )
    |> Repo.stream(max_rows: 100)
    |> Enum.reduce(MapSet.new(), fn {actor, inherited}, authors ->
      Enum.reduce(inherited, MapSet.put(authors, actor), &MapSet.put(&2, &1))
    end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp lock_board!(conversation_id, subject),
    do:
      Repo.one(
        from(b in Whiteboard,
          where:
            b.tenant_id == ^value(subject, :tenant_id) and b.conversation_id == ^conversation_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

  defp authorized_manage!(id, subject) do
    case Conversations.authorize_manage(id, subject) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp title_filter(query, ""), do: query

  defp title_filter(query, text),
    do: where(query, [b], fragment("strpos(lower(?), lower(?)) > 0", b.title, ^text))

  defp board_view(b),
    do: %BoardView{
      id: b.id,
      conversation_id: b.conversation_id,
      title: b.title,
      sequence: b.sequence,
      library_version: b.library_version,
      updated_at: b.updated_at
    }

  defp version_view(v),
    do: %VersionView{
      id: v.id,
      label: v.label,
      through_sequence: v.through_sequence,
      actor_user_id: v.actor_user_id,
      inserted_at: v.inserted_at
    }

  defp asset_view(a, r),
    do: %AssetView{
      id: a.id,
      attachment_id: a.attachment_id,
      source_message_id: a.source_message_id,
      content_type: r.content_type,
      byte_size: r.byte_size
    }

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_), do: ""

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp bounded(v, fallback, maximum) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> bounded(n, fallback, maximum)
      _ -> fallback
    end
  end

  defp bounded(v, _fallback, max) when is_integer(v), do: v |> max(1) |> min(max)
  defp bounded(_, fallback, _max), do: fallback
end
