defmodule CommsCore.Messaging.DeliveryCursors do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Conversations
  alias CommsCore.Messaging.{DeliveryCursorView, Message, MessageDeliveryCursor}
  alias CommsCore.Repo

  def mark_delivered(conversation_id, sequence, subject)
      when is_binary(conversation_id) and is_integer(sequence) and is_map(subject) do
    advance(conversation_id, sequence, nil, subject)
  end

  def mark_delivered(_, _, _), do: {:error, :invalid_sequence}

  def mark_read(conversation_id, sequence, subject)
      when is_binary(conversation_id) and is_integer(sequence) and is_map(subject) do
    advance(conversation_id, sequence, sequence, subject)
  end

  def mark_read(_, _, _), do: {:error, :invalid_sequence}

  def list(conversation_id, subject) when is_binary(conversation_id) and is_map(subject) do
    with :ok <- Conversations.authorize_read(conversation_id, subject) do
      cursors =
        MessageDeliveryCursor
        |> where(
          [cursor],
          cursor.tenant_id == ^value(subject, :tenant_id) and
            cursor.conversation_id == ^conversation_id
        )
        |> order_by([cursor], asc: cursor.user_id, asc: cursor.id)
        |> Repo.all()
        |> Enum.map(&project(&1, conversation_id))

      {:ok, cursors}
    end
  end

  def list(_, _), do: {:error, :not_found}

  defp advance(conversation_id, delivered_sequence, read_sequence, subject) do
    with :ok <- Conversations.authorize_read(conversation_id, subject),
         {:ok, target} <- bounded_sequence(conversation_id, delivered_sequence, subject) do
      timestamp = now()
      read_target = if is_integer(read_sequence), do: target, else: 0

      attrs = %{
        id: Ecto.UUID.generate(),
        tenant_id: value(subject, :tenant_id),
        conversation_id: conversation_id,
        user_id: value(subject, :user_id),
        device_id: value(subject, :device_id),
        delivered_sequence: target,
        read_sequence: read_target,
        delivered_at: if(target > 0, do: timestamp),
        read_at: if(read_target > 0, do: timestamp),
        inserted_at: timestamp,
        updated_at: timestamp
      }

      conflict =
        from(cursor in MessageDeliveryCursor,
          update: [
            set: [
              delivered_sequence:
                fragment(
                  "GREATEST(?, EXCLUDED.delivered_sequence)",
                  cursor.delivered_sequence
                ),
              read_sequence:
                fragment("GREATEST(?, EXCLUDED.read_sequence)", cursor.read_sequence),
              delivered_at:
                fragment(
                  "CASE WHEN EXCLUDED.delivered_sequence > ? THEN EXCLUDED.delivered_at ELSE ? END",
                  cursor.delivered_sequence,
                  cursor.delivered_at
                ),
              read_at:
                fragment(
                  "CASE WHEN EXCLUDED.read_sequence > ? THEN EXCLUDED.read_at ELSE ? END",
                  cursor.read_sequence,
                  cursor.read_at
                ),
              updated_at: ^timestamp
            ]
          ]
        )

      Repo.insert_all(MessageDeliveryCursor, [attrs],
        on_conflict: conflict,
        conflict_target: [:tenant_id, :conversation_id, :user_id, :device_id]
      )

      cursor =
        Repo.get_by!(MessageDeliveryCursor,
          tenant_id: value(subject, :tenant_id),
          conversation_id: conversation_id,
          user_id: value(subject, :user_id),
          device_id: value(subject, :device_id)
        )

      {:ok, project(cursor, conversation_id)}
    end
  end

  defp bounded_sequence(conversation_id, requested, subject) when requested >= 0 do
    maximum =
      Message
      |> where(
        [message],
        message.tenant_id == ^value(subject, :tenant_id) and
          message.conversation_id == ^conversation_id
      )
      |> select([message], max(message.conversation_sequence))
      |> Repo.one()
      |> Kernel.||(0)

    {:ok, min(requested, maximum)}
  end

  defp bounded_sequence(_, _, _), do: {:error, :invalid_sequence}

  defp project(cursor, conversation_id) do
    %DeliveryCursorView{
      recipient_user_id: cursor.user_id,
      device_ref: device_ref(conversation_id, cursor.device_id),
      delivered_sequence: cursor.delivered_sequence,
      read_sequence: cursor.read_sequence,
      delivered_at: cursor.delivered_at,
      read_at: cursor.read_at
    }
  end

  defp device_ref(conversation_id, device_id) do
    :crypto.hash(:sha256, conversation_id <> ":" <> device_id)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
