defmodule CommsWorkers.EphemeralRoomLifecycleWorker do
  @moduledoc """
  Applies generation-fenced expiry to an idle ephemeral communication room.

  The Conversations context owns all lifecycle decisions and durable state.
  This adapter only translates the domain result into bounded Oban retry
  semantics.
  """

  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:room_id, :generation],
      states: :incomplete
    ]

  alias CommsCore.Conversations

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"room_id" => room_id, "generation" => generation}
      })
      when is_binary(room_id) and is_integer(generation) and generation >= 1 do
    case Conversations.expire_ephemeral_room(room_id, generation, __MODULE__) do
      {:ok, :expired} ->
        :ok

      {:ok, :already_terminal} ->
        :ok

      {:ok, :active} ->
        :ok

      {:ok, :stale_generation} ->
        :ok

      {:ok, {:not_due, seconds}} when is_integer(seconds) ->
        {:snooze, max(seconds, 1)}

      {:error, :ephemeral_room_not_found} ->
        {:discard, :ephemeral_room_not_found}

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :room_id_and_generation_required}

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :ephemeral_room_expiry_failed
end
