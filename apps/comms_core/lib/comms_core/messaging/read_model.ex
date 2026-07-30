defmodule CommsCore.Messaging.ReadModel do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Messaging.{Message, Projector}

  @doc false
  def retained_sender_labels(messages, subject, opts) do
    if Keyword.get(opts, :include_sender_labels, false) do
      sender_ids =
        messages
        |> Enum.map(& &1.sender_user_id)
        |> Enum.uniq()

      Accounts.resolve_retained_sender_labels(value(subject, :tenant_id), sender_ids)
    else
      []
    end
  end

  @doc false
  def hydrate_message(%Message{} = message) do
    [hydrated] = hydrate_messages([message])
    hydrated
  end

  @doc false
  def hydrate_messages([]), do: []

  def hydrate_messages(messages) do
    messages = Repo.preload(messages, [:attachments, :reactions, :mentions], force: true)

    root_ids =
      messages
      |> Enum.map(&(&1.thread_root_message_id || &1.id))
      |> Enum.uniq()

    counts =
      Repo.all(
        from(message in Message,
          where: message.thread_root_message_id in ^root_ids,
          group_by: message.thread_root_message_id,
          select: {message.thread_root_message_id, count(message.id)}
        )
      )
      |> Map.new()

    Enum.map(messages, fn message ->
      root_id = message.thread_root_message_id || message.id
      Projector.message(message, Map.get(counts, root_id, 0))
    end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
