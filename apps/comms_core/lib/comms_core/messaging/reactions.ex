defmodule CommsCore.Messaging.Reactions do
  @moduledoc false

  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Messaging.{Message, Projector, Reaction}

  def add_reaction(message_id, emoji, subject) when is_binary(emoji) do
    mutation(message_id, subject, fn message ->
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
        {:ok, reaction} -> Projector.reaction(reaction)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def remove_reaction(message_id, emoji, subject) do
    case mutation(message_id, subject, fn message ->
           query =
             from(r in Reaction,
               where:
                 r.message_id == ^message.id and r.tenant_id == ^message.tenant_id and
                   r.user_id == ^value(subject, :user_id) and r.emoji == ^emoji
             )

           case Repo.delete_all(query) do
             {1, _} -> :ok
             _ -> Repo.rollback(:not_found)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  defp mutation(message_id, subject, operation) do
    with %Message{} = snapshot <- scoped_message(message_id, subject),
         :ok <- authorize_reaction(snapshot, subject) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          budget!(deadline)

          case Accounts.lock_content_write_grant(subject, deadline) do
            {:ok, _grant} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          budget!(deadline)

          case Conversations.lock_call_conversation(
                 snapshot.tenant_id,
                 snapshot.conversation_id,
                 :share
               ) do
            {:ok, _conversation} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          current_grant!(subject, deadline)
          budget!(deadline)

          message =
            Repo.one(
              from(m in Message,
                where:
                  m.id == ^snapshot.id and m.tenant_id == ^snapshot.tenant_id and
                    m.status == :active,
                lock: "FOR SHARE"
              )
            ) || Repo.rollback(:not_found)

          current_authority!(message, subject, deadline)
          result = operation.(message)
          current_authority!(message, subject, deadline)
          result
        end,
        timeout: 20_000
      )
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp current_authority!(message, subject, deadline) do
    current_grant!(subject, deadline)

    case authorize_reaction(message, subject) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    budget!(deadline)
  end

  defp current_grant!(subject, deadline) do
    budget!(deadline)

    case Accounts.access_grant(subject) do
      {:ok, _grant} -> :ok
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

  defp authorize_reaction(%Message{} = message, subject) do
    with true <- message.tenant_id == value(subject, :tenant_id),
         :ok <- Conversations.authorize_react_message(message.conversation_id, subject) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp scoped_message(message_id, subject) do
    Repo.get_by(Message, id: message_id, tenant_id: value(subject, :tenant_id), status: :active)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
