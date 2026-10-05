defmodule CommsCore.Whiteboards.Commands do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Repo}

  alias CommsCore.Whiteboards.{
    Operation,
    Payload,
    Projector,
    Snapshots,
    Version,
    Whiteboard,
    WriteFence
  }

  @maximum_operations 100_000

  def append(conversation_id, attrs, subject) when is_binary(conversation_id) and is_map(attrs) do
    append_with_source(conversation_id, attrs, subject, nil, write_deadline())
  end

  def append(_, _, _), do: {:error, :invalid_whiteboard_operation}

  # Library restore shares its existing absolute transaction budget with every
  # append; it must not grant another 15 seconds to each restored chunk.
  @doc false
  def append(conversation_id, attrs, subject, deadline)
      when is_binary(conversation_id) and is_map(attrs) and is_integer(deadline) do
    if Repo.in_transaction?(),
      do: append_with_source(conversation_id, attrs, subject, nil, deadline),
      else: {:error, :transaction_required}
  end

  # The checkpoint is reloaded under the board lock. No caller-supplied lineage
  # or client payload can assign another user's authorship to an operation.
  def append_restored(conversation_id, attrs, subject, %Version{id: id})
      when is_binary(conversation_id) and is_map(attrs) and is_binary(id) do
    if Repo.in_transaction?(),
      do: append_with_source(conversation_id, attrs, subject, id, write_deadline()),
      else: {:error, :transaction_required}
  end

  def append_restored(_, _, _, _), do: {:error, :invalid_whiteboard_operation}

  @doc false
  def append_restored(conversation_id, attrs, subject, %Version{id: id}, deadline)
      when is_binary(conversation_id) and is_map(attrs) and is_binary(id) and
             is_integer(deadline) do
    if Repo.in_transaction?(),
      do: append_with_source(conversation_id, attrs, subject, id, deadline),
      else: {:error, :transaction_required}
  end

  defp append_with_source(conversation_id, attrs, subject, source_version_id, deadline) do
    tenant_id = value(subject, :tenant_id)
    actor_user_id = value(subject, :user_id)
    actor_device_id = value(subject, :device_id)
    client_operation_id = value(attrs, :client_operation_id)
    kind = value(attrs, :kind)
    payload = value(attrs, :payload) || %{}
    base_sequence = value(attrs, :base_sequence)

    with :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject),
         {:ok, client_operation_id} <- client_operation_id(client_operation_id),
         {:ok, base_sequence} <- base_sequence(kind, base_sequence),
         {:ok, payload} <- Payload.validate(kind, payload) do
      Repo.transaction(
        fn ->
          lock_write_authority!(conversation_id, subject, deadline)

          write_budget!(deadline)
          whiteboard = lock_or_create_whiteboard!(tenant_id, conversation_id, deadline)
          current_write_authority!(conversation_id, subject, deadline, :use)
          source_actor_user_ids = source_authors!(whiteboard, source_version_id)

          write_budget!(deadline)

          case CommsCore.Whiteboards.AssetValidation.validate(
                 whiteboard,
                 Map.get(payload, "elements", []),
                 subject
               ) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          result =
            case existing_operation(
                   tenant_id,
                   actor_device_id,
                   conversation_id,
                   client_operation_id
                 ) do
              %Operation{} = operation ->
                if operation.kind == kind and operation.payload == payload and
                     operation.source_actor_user_ids == source_actor_user_ids do
                  {Projector.operation(operation), :duplicate}
                else
                  Repo.rollback(:idempotency_conflict)
                end

              nil ->
                generation = current_generation(whiteboard)
                ensure_capacity_and_generation!(whiteboard, kind, base_sequence, generation)

                prepared =
                  case Snapshots.prepare(whiteboard, generation, kind, payload) do
                    {:ok, prepared} -> prepared
                    {:error, reason} -> Repo.rollback(reason)
                  end

                current_write_authority!(conversation_id, subject, deadline, :use)
                sequence = whiteboard.sequence + 1

                write_budget!(deadline)

                operation =
                  %Operation{}
                  |> Operation.changeset(%{
                    whiteboard_id: whiteboard.id,
                    tenant_id: tenant_id,
                    conversation_id: conversation_id,
                    actor_user_id: actor_user_id,
                    actor_device_id: actor_device_id,
                    client_operation_id: client_operation_id,
                    sequence: sequence,
                    kind: kind,
                    payload: payload,
                    source_actor_user_ids: source_actor_user_ids
                  })
                  |> Repo.insert!()

                write_budget!(deadline)

                whiteboard
                |> Ecto.Changeset.change(sequence: sequence)
                |> Repo.update!()

                # Inside the same transaction and under the same row lock, so the
                # snapshot can only ever describe committed operations.
                write_budget!(deadline)
                Snapshots.maintain(whiteboard, sequence, prepared)

                {Projector.operation(operation), :created}
            end

          current_write_authority!(conversation_id, subject, deadline, :use)
          result
        end,
        timeout: 20_000
      )
      |> case do
        {:ok, result} -> {:ok, elem(result, 0), elem(result, 1)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def write_deadline, do: System.monotonic_time(:millisecond) + 15_000

  @doc false
  def lock_write_authority!(conversation_id, subject, deadline) do
    write_budget!(deadline)

    case Accounts.lock_content_write_grant(subject, deadline) do
      {:ok, _grant} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    write_budget!(deadline)

    case Conversations.lock_call_conversation(value(subject, :tenant_id), conversation_id, :share) do
      {:ok, _conversation} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    write_budget!(deadline)
    WriteFence.lock_author!(value(subject, :tenant_id), value(subject, :user_id))
    current_write_authority!(conversation_id, subject, deadline, :use)
  end

  @doc false
  def current_write_authority!(conversation_id, subject, deadline, permission) do
    write_budget!(deadline)

    case Accounts.access_grant(subject) do
      {:ok, _grant} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    write_budget!(deadline)

    authorized =
      case permission do
        :use -> Conversations.authorize_use_whiteboard(conversation_id, subject)
        :manage -> Conversations.authorize_manage(conversation_id, subject)
      end

    case authorized do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    write_budget!(deadline)
  end

  @doc false
  def write_budget!(deadline) do
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

  defp source_authors!(_whiteboard, nil), do: []

  defp source_authors!(whiteboard, source_version_id) do
    case Repo.get_by(Version,
           id: source_version_id,
           tenant_id: whiteboard.tenant_id,
           whiteboard_id: whiteboard.id
         ) do
      %Version{} = version -> version.source_actor_user_ids
      nil -> Repo.rollback(:not_found)
    end
  end

  defp lock_or_create_whiteboard!(tenant_id, conversation_id, deadline) do
    write_budget!(deadline)

    %Whiteboard{}
    |> Whiteboard.changeset(%{
      tenant_id: tenant_id,
      conversation_id: conversation_id,
      sequence: 0
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :conversation_id]
    )

    write_budget!(deadline)

    Repo.one!(
      from(whiteboard in Whiteboard,
        where:
          whiteboard.tenant_id == ^tenant_id and
            whiteboard.conversation_id == ^conversation_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp existing_operation(tenant_id, actor_device_id, conversation_id, client_operation_id) do
    Repo.get_by(Operation,
      tenant_id: tenant_id,
      actor_device_id: actor_device_id,
      conversation_id: conversation_id,
      client_operation_id: client_operation_id
    )
  end

  defp client_operation_id(value) when is_binary(value) do
    value = String.trim(value)
    if byte_size(value) in 8..128, do: {:ok, value}, else: {:error, :invalid_whiteboard_operation}
  end

  defp client_operation_id(_), do: {:error, :invalid_whiteboard_operation}

  defp base_sequence("scene.update", nil), do: {:ok, 0}

  defp base_sequence("scene.update", value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp base_sequence("scene.update", _), do: {:error, :invalid_whiteboard_operation}
  defp base_sequence(_kind, _value), do: {:ok, 0}

  defp current_generation(whiteboard) do
    Repo.one(
      from(operation in Operation,
        where:
          operation.whiteboard_id == ^whiteboard.id and
            operation.kind == "board.clear",
        select: max(operation.sequence)
      )
    ) || 0
  end

  defp ensure_capacity_and_generation!(whiteboard, "scene.update", base_sequence, generation) do
    if base_sequence < generation,
      do: Repo.rollback(:stale_whiteboard_generation)

    if whiteboard.sequence - generation >= @maximum_operations,
      do: Repo.rollback(:whiteboard_capacity_exceeded)
  end

  defp ensure_capacity_and_generation!(_whiteboard, "board.clear", _base_sequence, _generation),
    do: :ok

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
