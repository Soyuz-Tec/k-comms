defmodule CommsCore.Messaging.Activity do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Messaging.{ActivityView, Message}

  def list(conversation_id, subject, opts \\ [])

  def list(conversation_id, subject, opts)
      when is_binary(conversation_id) and is_map(subject) do
    with :ok <- Conversations.authorize_read(conversation_id, subject) do
      limit = limit(Keyword.get(opts, :limit, 50))

      entries =
        Message
        |> where(
          [message],
          message.tenant_id == ^value(subject, :tenant_id) and
            message.conversation_id == ^conversation_id
        )
        |> order_by([message], desc: message.inserted_at, desc: message.conversation_sequence)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.map(fn message ->
          %ActivityView{
            id: message.id,
            conversation_id: message.conversation_id,
            actor_user_id: message.sender_user_id,
            kind: activity_kind(message),
            sequence: message.conversation_sequence,
            occurred_at: message.edited_at || message.deleted_at || message.inserted_at
          }
        end)

      {:ok, entries}
    end
  end

  def list(_, _, _), do: {:error, :not_found}

  defp activity_kind(%Message{status: status}) when status in [:deleted, :moderated],
    do: "message.#{status}"

  defp activity_kind(%Message{edited_at: edited_at}) when not is_nil(edited_at),
    do: "message.updated"

  defp activity_kind(_message), do: "message.created"

  defp limit(value) when is_integer(value), do: value |> max(1) |> min(100)
  defp limit(_), do: 50
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
