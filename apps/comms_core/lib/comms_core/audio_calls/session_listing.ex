defmodule CommsCore.AudioCalls.SessionListing do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts
  alias CommsCore.AudioCalls.{AudioCall, CallSessionView, Projector}
  alias CommsCore.{Conversations, Repo}

  @media_kinds [:audio, :video]
  @default_session_limit 30
  @max_session_limit 100

  @spec list(map(), map()) ::
          {:ok,
           %{
             calls: [CallSessionView.t()],
             limit: pos_integer(),
             has_more: boolean(),
             next_cursor: String.t() | nil
           }}
          | {:error, :forbidden | :invalid_call_scope | :invalid_media_kind | :invalid_cursor}
  def list(subject, params) when is_map(subject) and is_map(params) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, scope} <- call_scope(value(params, :scope)),
         {:ok, media_kind} <- optional_media_kind(value(params, :media_kind)),
         {:ok, cursor} <- optional_call_cursor(value(params, :cursor)) do
      observed_at = now()
      authorization_query = Conversations.active_membership_authorization_query(grant)
      limit = session_limit(value(params, :limit))

      results =
        from(call in AudioCall,
          as: :call,
          join: authorization in subquery(authorization_query),
          as: :conversation_authorization,
          on: authorization.conversation_id == call.conversation_id,
          where: call.tenant_id == ^grant.tenant_id,
          select: %{call: call, membership_role: authorization.membership_role}
        )
        |> maybe_filter_call_scope(scope, observed_at)
        |> maybe_filter_media_kind(media_kind)
        |> maybe_before_call_cursor(cursor)
        |> order_by([call: call], desc: call.started_at, desc: call.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      has_more = length(results) > limit

      calls =
        results
        |> Enum.take(limit)
        |> Enum.map(fn %{call: call, membership_role: membership_role} ->
          can_end =
            call.status == :active and
              (call.started_by_user_id == grant.user_id or
                 membership_role in [:owner, :moderator])

          Projector.call_session(call, can_end, observed_at)
        end)

      {:ok,
       %{
         calls: calls,
         limit: limit,
         has_more: has_more,
         next_cursor: if(has_more, do: call_cursor_for(List.last(calls)), else: nil)
       }}
    end
  end

  def list(_subject, _params), do: {:error, :forbidden}

  defp call_scope(nil), do: {:ok, :recent}
  defp call_scope(""), do: {:ok, :recent}
  defp call_scope(:active), do: {:ok, :active}
  defp call_scope("active"), do: {:ok, :active}
  defp call_scope(:recent), do: {:ok, :recent}
  defp call_scope("recent"), do: {:ok, :recent}
  defp call_scope(_value), do: {:error, :invalid_call_scope}

  defp optional_media_kind(nil), do: {:ok, nil}
  defp optional_media_kind(""), do: {:ok, nil}
  defp optional_media_kind(media_kind) when media_kind in @media_kinds, do: {:ok, media_kind}
  defp optional_media_kind("audio"), do: {:ok, :audio}
  defp optional_media_kind("video"), do: {:ok, :video}
  defp optional_media_kind(_value), do: {:error, :invalid_media_kind}

  defp maybe_filter_call_scope(query, :active, observed_at) do
    where(
      query,
      [call: call],
      call.status == :ending or
        (call.status == :active and call.expires_at > ^observed_at)
    )
  end

  defp maybe_filter_call_scope(query, :recent, _observed_at),
    do: where(query, [call: call], call.status == :ended)

  defp maybe_filter_media_kind(query, nil), do: query

  defp maybe_filter_media_kind(query, media_kind),
    do: where(query, [call: call], call.media_kind == ^media_kind)

  defp optional_call_cursor(nil), do: {:ok, nil}
  defp optional_call_cursor(""), do: {:ok, nil}

  defp optional_call_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"started_at" => started_at, "id" => id, "v" => 1}} <-
           Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, call_id} <- Ecto.UUID.cast(id) do
      {:ok, {DateTime.truncate(timestamp, :microsecond), call_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_call_cursor(_value), do: {:error, :invalid_cursor}

  defp maybe_before_call_cursor(query, nil), do: query

  defp maybe_before_call_cursor(query, {timestamp, call_id}) do
    where(
      query,
      [call: call],
      call.started_at < ^timestamp or
        (call.started_at == ^timestamp and call.id < ^call_id)
    )
  end

  defp call_cursor_for(nil), do: nil

  defp call_cursor_for(%CallSessionView{} = call) do
    %{v: 1, started_at: DateTime.to_iso8601(call.started_at), id: call.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp session_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_session_limit)

  defp session_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> session_limit(number)
      _ -> @default_session_limit
    end
  end

  defp session_limit(_value), do: @default_session_limit

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
