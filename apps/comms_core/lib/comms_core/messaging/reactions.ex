defmodule CommsCore.Messaging.Reactions do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Messaging.{Message, Projector, Reaction}

  def add_reaction(message_id, emoji, subject) when is_binary(emoji) do
    with %Message{} = message <- scoped_message(message_id, subject),
         :ok <- authorize_reaction(message, subject) do
      changeset =
        Reaction.changeset(%Reaction{}, %{
          tenant_id: message.tenant_id,
          message_id: message.id,
          user_id: value(subject, :user_id),
          emoji: emoji
        })

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:message_id, :user_id, :emoji],
             returning: true
           ) do
        {:ok, reaction} -> {:ok, Projector.reaction(reaction)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def remove_reaction(message_id, emoji, subject) do
    with %Message{} = message <- scoped_message(message_id, subject),
         :ok <- authorize_reaction(message, subject) do
      query =
        from(r in Reaction,
          where:
            r.message_id == ^message_id and r.tenant_id == ^value(subject, :tenant_id) and
              r.user_id == ^value(subject, :user_id) and r.emoji == ^emoji
        )

      case Repo.delete_all(query) do
        {1, _} -> :ok
        _ -> {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp authorize_reaction(%Message{} = message, subject) do
    with true <- same_tenant?(message, subject),
         :ok <- Conversations.authorize_react_message(message.conversation_id, subject) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp same_tenant?(%Message{tenant_id: tenant_id}, subject),
    do: tenant_id == value(subject, :tenant_id)

  defp scoped_message(message_id, subject) do
    Repo.get_by(Message, id: message_id, tenant_id: value(subject, :tenant_id))
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
