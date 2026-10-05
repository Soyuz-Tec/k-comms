defmodule CommsCore.Governance.DeletionRequestHistory do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Audit, Repo}
  alias CommsCore.Audit.ResourceHistoryQuery
  alias CommsCore.Accounts.AccessGrant

  alias CommsCore.Governance.{
    Authorization,
    DeletionRequest,
    DeletionRequestHistoryExport,
    DeletionRequestTimeline,
    HistoryCursor,
    HistoryProjection,
    TenantLock
  }

  import CommsCore.Governance.Support, only: [value: 2, transaction_result: 1, audit!: 5]

  @budget_ms 15_000
  @default_page_limit 25
  @maximum_page_limit 50
  @maximum_export_limit 5_000

  def timeline(id, params, subject) when is_map(params) and is_map(subject) do
    with :ok <- Authorization.authorize(subject),
         {:ok, id} <- cast_id(id),
         {:ok, _key} <- HistoryCursor.configured?(),
         {:ok, cursor, limit} <- page_position(id, params, subject) do
      authorized_transaction(id, subject, fn request, deadline ->
        page = read_page!(id, subject, cursor, limit, deadline)

        cursor =
          cursor ||
            HistoryCursor.new(value(subject, :tenant_id), id, page.snapshot_id, page.observed_at)

        events =
          budgeted(deadline, fn -> HistoryProjection.events(request.tenant_id, page.events) end)

        snapshot = seal!(%{cursor | after: nil, limit: nil}, :snapshot)

        next_cursor =
          if page.has_more do
            last = List.last(page.events)
            seal!(%{cursor | after: {last.inserted_at, last.id}, limit: limit}, :cursor)
          end

        {%DeletionRequestTimeline{
           request: HistoryProjection.request(request),
           events: events,
           limit: limit,
           next_cursor: next_cursor,
           snapshot: snapshot,
           observed_at: now(),
           snapshot_observed_at: cursor.observed_at,
           coverage: HistoryProjection.coverage(page)
         }, page.expires_at}
      end)
    end
  end

  def timeline(_, _, _), do: {:error, :forbidden}

  def export(id, params, subject) when is_map(params) and is_map(subject) do
    with :ok <- Authorization.authorize(subject),
         {:ok, id} <- cast_id(id),
         {:ok, _key} <- HistoryCursor.configured?(),
         {:ok, cursor} <- optional_snapshot(value(params, :snapshot), id, subject),
         {:ok, limit} <-
           parse_limit(value(params, :limit), @maximum_export_limit, @maximum_export_limit),
         true <- is_nil(value(params, :cursor)) do
      authorized_transaction(id, subject, fn request, deadline ->
        page = read_page!(id, subject, cursor, limit, deadline)

        cursor =
          cursor || HistoryCursor.new(request.tenant_id, id, page.snapshot_id, page.observed_at)

        events =
          budgeted(deadline, fn -> HistoryProjection.events(request.tenant_id, page.events) end)

        csv = encode_csv(events)
        coverage = HistoryProjection.coverage(page)
        truncated = page.has_more or page.snapshot_truncated
        current_authority!(subject, deadline)

        budgeted(deadline, fn ->
          audit!(subject, "deletion_request.history_export", "deletion_request", id, %{
            returned_count: length(events),
            truncated: truncated,
            maximum_rows: @maximum_export_limit,
            coverage: coverage.state
          })
        end)

        {%DeletionRequestHistoryExport{
           csv: csv,
           filename: "deletion-request-history.csv",
           count: length(events),
           truncated: truncated,
           maximum_rows: @maximum_export_limit,
           snapshot: seal!(%{cursor | after: nil, limit: nil}, :snapshot),
           observed_at: now(),
           coverage: coverage
         }, page.expires_at}
      end)
    else
      false -> {:error, :invalid_history_cursor}
      {:error, _} = error -> error
    end
  end

  def export(_, _, _), do: {:error, :forbidden}

  defp authorized_transaction(id, subject, operation) do
    Repo.transaction(
      fn ->
        deadline = System.monotonic_time(:millisecond) + @budget_ms
        # Deletion workers take this fence before Request and Identity rows.
        # Taking it first prevents a reader User -> Request / worker Request ->
        # User inversion, including owner actor deletion by the same request.
        budgeted(deadline, fn -> TenantLock.lock!(value(subject, :tenant_id)) end)
        current_authority!(subject, deadline)

        request =
          budgeted(deadline, fn ->
            Repo.one(
              from(request in DeletionRequest,
                where: request.id == ^id and request.tenant_id == ^value(subject, :tenant_id),
                lock: "FOR SHARE"
              )
            )
          end) || Repo.rollback(:not_found)

        current_authority!(subject, deadline)
        {result, snapshot_expires_at} = operation.(request, deadline)
        # Return only after all lower-resource/query/CSV waits and CPU work have
        # passed the same current initiating tuple, role and fresh step-up fence.
        current_authority!(subject, deadline)

        if DateTime.compare(snapshot_expires_at, now()) != :gt,
          do: Repo.rollback(:invalid_history_cursor)

        result
      end,
      timeout: @budget_ms + 5_000
    )
    |> transaction_result()
  end

  defp current_authority!(subject, deadline) do
    case Accounts.lock_content_write_grant(subject, deadline) do
      {:ok, %AccessGrant{} = grant} ->
        cond do
          grant.account_type != :human or grant.access_scope != :workspace or
              grant.role not in [:owner, :compliance_admin] ->
            Repo.rollback(:forbidden)

          not grant.step_up_recent? ->
            Repo.rollback(:step_up_required)

          true ->
            budget!(deadline)
        end

      {:error, _} ->
        Repo.rollback(:forbidden)
    end
  end

  defp read_page!(id, subject, cursor, limit, deadline) do
    query = %ResourceHistoryQuery{
      tenant_id: value(subject, :tenant_id),
      resource_type: "deletion_request",
      resource_id: id,
      actions: HistoryProjection.actions(),
      origin_action: "deletion_request.create",
      limit: limit,
      deadline: deadline,
      snapshot_id: cursor && cursor.snapshot_id,
      after: cursor && cursor.after
    }

    case budgeted(deadline, fn -> Audit.resource_history_page(query) end) do
      {:ok, page} ->
        if DateTime.compare(page.expires_at, now()) != :gt,
          do: Repo.rollback(:invalid_history_cursor)

        page

      {:error, :audit_history_snapshot_unavailable} ->
        Repo.rollback(:invalid_history_cursor)

      {:error, _} ->
        Repo.rollback(:history_unavailable)
    end
  end

  defp page_position(id, params, subject) do
    case {value(params, :cursor), value(params, :snapshot)} do
      {nil, snapshot} ->
        with {:ok, cursor} <- optional_snapshot(snapshot, id, subject),
             {:ok, limit} <-
               parse_limit(value(params, :limit), @default_page_limit, @maximum_page_limit),
             do: {:ok, cursor, limit}

      {token, nil} ->
        with {:ok, cursor} <- HistoryCursor.open(token, :cursor, value(subject, :tenant_id), id),
             {:ok, limit} <- parse_limit(value(params, :limit), cursor.limit, @maximum_page_limit),
             true <- limit == cursor.limit,
             do: {:ok, cursor, limit},
             else: (_ -> {:error, :invalid_history_cursor})

      _ ->
        {:error, :invalid_history_cursor}
    end
  end

  defp optional_snapshot(nil, _id, _subject), do: {:ok, nil}

  defp optional_snapshot(token, id, subject),
    do: HistoryCursor.open(token, :snapshot, value(subject, :tenant_id), id)

  defp parse_limit(nil, default, _maximum), do: {:ok, default}

  defp parse_limit(value, _default, maximum) when is_integer(value) and value in 1..maximum//1,
    do: {:ok, value}

  defp parse_limit(value, default, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_limit(number, default, maximum)
      _ -> {:error, :invalid_history_limit}
    end
  end

  defp parse_limit(_, _, _), do: {:error, :invalid_history_limit}

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp seal!(cursor, kind) do
    case HistoryCursor.seal(cursor, kind) do
      {:ok, token} -> token
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp budgeted(deadline, operation) do
    budget!(deadline)
    result = operation.()
    budget!(deadline)
    result
  end

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:history_unavailable)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:history_unavailable)
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp encode_csv(events) do
    header =
      ~w(inserted_at actor_user_id actor_kind actor action status attempt error_code version proof_versions counts)

    rows =
      Enum.map(events, fn event ->
        [
          DateTime.to_iso8601(event.inserted_at),
          event.actor.user_id,
          event.actor.kind,
          event.actor.display_name,
          event.action,
          event.status,
          event.attempt,
          event.error_code,
          event.version,
          Jason.encode!(event.proof_versions),
          Jason.encode!(event.counts)
        ]
      end)

    ([header] ++ rows)
    |> Enum.map_join("\r\n", fn row -> Enum.map_join(row, ",", &csv_cell/1) end)
    |> Kernel.<>("\r\n")
  end

  defp csv_cell(nil), do: "\"\""

  defp csv_cell(value) do
    text = value |> to_string() |> String.replace(<<0>>, "")
    text = if Regex.match?(~r/^\s*[=+\-@\t\r]/u, text), do: "'" <> text, else: text
    "\"" <> String.replace(text, "\"", "\"\"") <> "\""
  end
end
