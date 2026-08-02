defmodule CommsCore.Whiteboards.Commands do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Whiteboards.{Operation, Payload, Projector, Snapshots, Whiteboard}

  @maximum_operations 100_000

  def append(conversation_id, attrs, subject) when is_binary(conversation_id) and is_map(attrs) do
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
      Repo.transaction(fn ->
        whiteboard = lock_or_create_whiteboard!(tenant_id, conversation_id)

        case existing_operation(
               tenant_id,
               actor_device_id,
               conversation_id,
               client_operation_id
             ) do
          %Operation{} = operation ->
            if operation.kind == kind and operation.payload == payload do
              {Projector.operation(operation), :duplicate}
            else
              Repo.rollback(:idempotency_conflict)
            end

          nil when whiteboard.sequence >= @maximum_operations ->
            Repo.rollback(:whiteboard_capacity_exceeded)

          nil ->
            ensure_current_generation!(whiteboard, kind, base_sequence)
            sequence = whiteboard.sequence + 1

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
                payload: payload
              })
              |> Repo.insert!()

            whiteboard
            |> Ecto.Changeset.change(sequence: sequence)
            |> Repo.update!()

            # Inside the same transaction and under the same row lock, so the
            # snapshot can only ever describe committed operations.
            Snapshots.maintain(whiteboard, sequence)

            {Projector.operation(operation), :created}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, elem(result, 0), elem(result, 1)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def append(_, _, _), do: {:error, :invalid_whiteboard_operation}

  defp lock_or_create_whiteboard!(tenant_id, conversation_id) do
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

  defp ensure_current_generation!(whiteboard, "scene.update", base_sequence) do
    latest_clear_sequence =
      Repo.one(
        from(operation in Operation,
          where:
            operation.whiteboard_id == ^whiteboard.id and
              operation.kind == "board.clear",
          select: max(operation.sequence)
        )
      ) || 0

    if base_sequence < latest_clear_sequence,
      do: Repo.rollback(:stale_whiteboard_generation)
  end

  defp ensure_current_generation!(_whiteboard, _kind, _base_sequence), do: :ok

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
