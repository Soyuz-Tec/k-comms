defmodule CommsWeb.ConversationActivityController do
  use CommsWeb, :controller

  alias CommsCore.{Attachments, AudioCalls, Messaging, Whiteboards}

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    subject = conn.assigns.current_subject
    limit = params["limit"] |> integer(50) |> max(1) |> min(100)

    with {:ok, messaging} <- Messaging.activity(conversation_id, subject, limit: limit),
         {:ok, whiteboard} <- Whiteboards.activity(conversation_id, subject, limit: limit),
         {:ok, calls} <- AudioCalls.activity(conversation_id, subject, limit: limit),
         {:ok, files} <-
           Attachments.list_files(subject, %{
             conversation_id: conversation_id,
             limit: limit
           }) do
      entries =
        Enum.map(messaging, &entry(&1, "messaging")) ++
          Enum.map(whiteboard, &entry(&1, "whiteboard")) ++
          Enum.map(calls, &entry(&1, "call")) ++
          Enum.map(files.files, &file_entry/1)

      data =
        entries
        |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
        |> Enum.take(limit)

      json(conn, %{data: data, page: %{limit: limit, has_more: length(entries) > limit}})
    end
  end

  defp entry(value, category) do
    %{
      id: value.id,
      category: category,
      conversation_id: value.conversation_id,
      actor_user_id: value.actor_user_id,
      kind: value.kind,
      sequence: Map.get(value, :sequence),
      occurred_at: value.occurred_at
    }
  end

  defp file_entry(file) do
    %{
      id: "#{file.id}:shared",
      category: "file",
      conversation_id: file.conversation_id,
      actor_user_id: file.owner_user_id,
      kind: "file.shared",
      sequence: file.conversation_sequence,
      occurred_at: file.shared_at,
      label: file.file_name
    }
  end

  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
end
