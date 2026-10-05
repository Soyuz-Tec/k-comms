defmodule CommsWeb.UnifiedSearchController do
  use CommsWeb, :controller
  alias CommsCore.{Attachments, AudioCalls, Messaging, Whiteboards}
  @kinds ~w(message file whiteboard meeting recording transcript)
  @source_limit 50

  def index(conn, %{"q" => raw} = params) when is_binary(raw) do
    subject = conn.assigns.current_subject
    query = String.trim(raw)
    kind = params["kind"] || "all"

    with true <- String.length(query) in 2..160 || {:error, :invalid_search_query},
         true <- kind in ["all" | @kinds] || {:error, :invalid_search_query},
         {:ok, cursor} <- cursor(params["cursor"], context(query, params, subject)),
         {:ok, messages} <-
           Messaging.search_page(query, subject,
             limit: 200,
             conversation_id: params["conversation_id"],
             sender_user_id: params["sender_user_id"],
             after: params["after"],
             before: params["before"]
           ),
         {:ok, files} <-
           Attachments.list_files(subject, %{
             q: query,
             conversation_id: params["conversation_id"],
             limit: 100
           }),
         {:ok, board_hits} <-
           Whiteboards.search(query, subject,
             limit: @source_limit,
             conversation_id: params["conversation_id"]
           ),
         {:ok, boards} <-
           Whiteboards.gallery(subject, %{
             q: query,
             conversation_id: params["conversation_id"],
             limit: @source_limit
           }),
         {:ok, meetings} <-
           AudioCalls.search_meetings(subject, %{
             q: query,
             conversation_id: params["conversation_id"],
             limit: @source_limit,
             after: params["after"],
             before: params["before"]
           }),
         {:ok, artifacts} <-
           AudioCalls.search_artifacts(subject, %{
             q: query,
             conversation_id: params["conversation_id"],
             limit: @source_limit + 1
           }) do
      candidates =
        Enum.map(messages.messages, &message_result/1) ++
          Enum.map(files.files, &file_result/1) ++
          Enum.map(board_hits, &board_hit_result/1) ++
          Enum.map(boards.boards, &board_result/1) ++
          Enum.map(meetings.meetings, &meeting_result/1) ++
          Enum.map(Enum.take(artifacts, @source_limit), &artifact_result/1)

      candidates =
        candidates
        |> Enum.filter(&matches_date?(&1, params))
        |> Enum.map(&rank(&1, query))
        |> Enum.sort_by(&sort_key/1)

      facets = Enum.frequencies_by(candidates, & &1.kind)
      limit = bounded(params["limit"], 25, 100)

      filtered =
        candidates
        |> Enum.filter(&(kind == "all" or &1.kind == kind))
        |> Enum.filter(&(is_nil(cursor) or sort_key(&1) > cursor))

      page = Enum.take(filtered, limit)
      more = length(filtered) > limit

      source_limits = %{
        messages: messages.has_more,
        files: files.has_more,
        whiteboards: length(board_hits) >= @source_limit or boards.truncated,
        meetings: meetings.truncated,
        artifacts: length(artifacts) > @source_limit
      }

      json(conn, %{
        data: page,
        facets: facets,
        page: %{
          has_more: more,
          next_cursor:
            if(more,
              do: encode_cursor(List.last(page), context(query, params, subject)),
              else: nil
            ),
          source_limits: source_limits,
          ranking_scope: "authorized_source_candidates",
          meeting_window_days: 732
        }
      })
    end
  end

  def index(_conn, _params), do: {:error, :invalid_search_query}

  defp message_result(m),
    do:
      result(
        m.id,
        "message",
        "Message",
        m.body || "Attachment",
        m.conversation_id,
        m.inserted_at,
        "/app/?conversation=#{URI.encode_www_form(m.conversation_id)}&message=#{URI.encode_www_form(m.id)}"
      )

  defp file_result(f),
    do:
      result(
        f.id,
        "file",
        f.file_name,
        f.content_type,
        f.conversation_id,
        f.shared_at,
        "/app/?conversation=#{URI.encode_www_form(f.conversation_id)}&message=#{URI.encode_www_form(f.message_id)}"
      )

  defp board_hit_result(b),
    do:
      result(
        "#{b.conversation_id}:#{b.element_id}",
        "whiteboard",
        "Board text",
        b.text,
        b.conversation_id,
        b.inserted_at,
        "/app/whiteboard?conversation=#{URI.encode_www_form(b.conversation_id)}&focus_elements=#{URI.encode_www_form(b.element_id)}"
      )

  defp board_result(b),
    do:
      result(
        b.id,
        "whiteboard",
        b.title,
        "Conversation whiteboard",
        b.conversation_id,
        b.updated_at,
        "/app/whiteboard?conversation=#{URI.encode_www_form(b.conversation_id)}"
      )

  defp meeting_result(m) do
    occurrence =
      Enum.find(m.occurrences, &(&1.status == "scheduled" or &1.status == :scheduled)) ||
        List.first(m.occurrences)

    result(
      m.id,
      "meeting",
      m.title,
      "Scheduled meeting · #{m.timezone}",
      m.conversation_id,
      if(occurrence, do: occurrence.starts_at, else: m.local_start),
      "/app/meetings?meeting=#{URI.encode_www_form(m.id)}"
    )
  end

  defp artifact_result(a) do
    kind = to_string(a.kind)

    result(
      a.id,
      kind,
      if(kind == "recording", do: "Meeting recording", else: "Meeting transcript"),
      "Available meeting artifact",
      a.conversation_id,
      a.started_at || a.created_at,
      "/app/artifacts?conversation=#{URI.encode_www_form(a.conversation_id)}&call=#{URI.encode_www_form(a.call_id)}&artifact=#{URI.encode_www_form(a.id)}"
    )
  end

  defp result(id, kind, title, excerpt, conversation_id, at, path),
    do: %{
      id: id,
      kind: kind,
      title: title,
      excerpt: String.slice(excerpt || "", 0, 280),
      conversation_id: conversation_id,
      occurred_at: iso(at),
      path: path,
      score: 0
    }

  defp rank(item, query) do
    title = String.downcase(item.title)
    text = String.downcase(item.title <> " " <> item.excerpt)
    tokens = String.split(String.downcase(query), ~r/\s+/u, trim: true)

    score =
      Enum.count(tokens, &String.contains?(text, &1)) * 20 +
        if(String.contains?(text, String.downcase(query)), do: 100, else: 0) +
        if(title == String.downcase(query), do: 200, else: 0)

    %{item | score: score}
  end

  defp sort_key(item), do: {-item.score, -unix(item.occurred_at), item.kind <> ":" <> item.id}

  defp matches_date?(item, params) do
    at = unix(item.occurred_at)

    (is_nil(params["after"]) or at >= unix(params["after"])) and
      (is_nil(params["before"]) or at < unix(params["before"]))
  end

  defp context(query, params, subject) do
    [
      query,
      Map.get(subject, :tenant_id),
      Map.get(subject, :user_id),
      params["conversation_id"],
      params["kind"],
      params["after"],
      params["before"],
      params["sender_user_id"]
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp cursor(nil, _context), do: {:ok, nil}
  defp cursor("", _context), do: {:ok, nil}

  defp cursor(value, context) when is_binary(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, %{"v" => 1, "context" => ^context, "key" => [score, timestamp, key]}} <-
           Jason.decode(json),
         true <-
           is_integer(score) and is_integer(timestamp) and is_binary(key) and byte_size(key) < 512 do
      {:ok, {score, timestamp, key}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_, _), do: {:error, :invalid_cursor}

  defp encode_cursor(item, context),
    do:
      %{v: 1, context: context, key: Tuple.to_list(sort_key(item))}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp iso(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso(at) when is_binary(at), do: at
  defp iso(_), do: "1970-01-01T00:00:00Z"

  defp unix(at) do
    case DateTime.from_iso8601(at || "") do
      {:ok, value, _} -> DateTime.to_unix(value, :microsecond)
      _ -> 0
    end
  end

  defp bounded(v, fallback, maximum) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> bounded(n, fallback, maximum)
      _ -> fallback
    end
  end

  defp bounded(v, _fallback, maximum) when is_integer(v), do: v |> max(1) |> min(maximum)
  defp bounded(_, fallback, _maximum), do: fallback
end
