defmodule CommsCore.AudioCalls.Activity do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.AudioCalls.{ActivityView, AudioCall, AuthorizationPolicy}
  alias CommsCore.Repo

  def list(conversation_id, subject, opts \\ [])

  def list(conversation_id, subject, opts)
      when is_binary(conversation_id) and is_map(subject) do
    with :ok <- AuthorizationPolicy.authorize(:read_call, subject, %{id: conversation_id}) do
      limit = limit(Keyword.get(opts, :limit, 50))

      calls =
        AudioCall
        |> where(
          [call],
          call.tenant_id == ^value(subject, :tenant_id) and
            call.conversation_id == ^conversation_id
        )
        |> order_by([call], desc: call.started_at, desc: call.id)
        |> limit(^limit)
        |> Repo.all()

      entries =
        calls
        |> Enum.flat_map(fn call ->
          started = %ActivityView{
            id: "#{call.id}:started",
            conversation_id: call.conversation_id,
            actor_user_id: call.started_by_user_id,
            kind: "call.#{call.media_kind}.started",
            occurred_at: call.started_at
          }

          ended =
            if call.ended_at do
              [
                %ActivityView{
                  id: "#{call.id}:ended",
                  conversation_id: call.conversation_id,
                  actor_user_id: call.ended_by_user_id || call.started_by_user_id,
                  kind: "call.#{call.media_kind}.ended",
                  occurred_at: call.ended_at
                }
              ]
            else
              []
            end

          [started | ended]
        end)
        |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
        |> Enum.take(limit)

      {:ok, entries}
    end
  end

  def list(_, _, _), do: {:error, :not_found}

  defp limit(value) when is_integer(value), do: value |> max(1) |> min(100)
  defp limit(_), do: 50
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
