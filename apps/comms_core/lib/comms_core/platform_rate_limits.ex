defmodule CommsCore.PlatformRateLimits do
  @moduledoc """
  Cluster-wide fixed-window admission for bounded platform interactions.

  Keys crossing this boundary must already be opaque 32-byte digests. Raw
  addresses, room tokens, and bearer credentials are rejected rather than
  persisted. PostgreSQL's clock and atomic upsert make the result consistent
  across all web nodes.
  """

  alias CommsCore.PlatformRateLimits.Decision
  alias CommsCore.Repo
  alias Ecto.Adapters.SQL

  @cleanup_limit 100
  @scopes [
    :instant_room_create,
    :instant_room_join,
    :instant_room_conversion,
    :instant_room_message,
    :instant_room_whiteboard,
    :direct_audio_join,
    :direct_audio_signal
  ]

  @consume_sql """
  WITH clock AS MATERIALIZED (
    SELECT floor(extract(epoch FROM clock_timestamp()))::bigint AS epoch_second
  ),
  expired AS MATERIALIZED (
    SELECT bucket.ctid
    FROM public_rate_limit_buckets AS bucket
    CROSS JOIN clock
    WHERE bucket.expires_at <= timezone('UTC', to_timestamp(clock.epoch_second))
    ORDER BY bucket.expires_at
    LIMIT $5::integer
    FOR UPDATE OF bucket SKIP LOCKED
  ),
  cleanup AS (
    DELETE FROM public_rate_limit_buckets AS bucket
    USING expired
    WHERE bucket.ctid = expired.ctid
    RETURNING 1
  ),
  current_window AS MATERIALIZED (
    SELECT
      clock.epoch_second,
      (clock.epoch_second / $4::bigint) * $4::bigint AS started_epoch,
      ((clock.epoch_second / $4::bigint) + 1) * $4::bigint AS ends_epoch
    FROM clock
  ),
  incremented AS (
    INSERT INTO public_rate_limit_buckets (
      scope,
      key_digest,
      window_seconds,
      window_started_at,
      request_count,
      expires_at
    )
    SELECT
      $1::text,
      $2::bytea,
      $4::bigint,
      timezone('UTC', to_timestamp(current_window.started_epoch)),
      $6::bigint,
      timezone('UTC', to_timestamp(current_window.ends_epoch))
    FROM current_window
    ON CONFLICT (scope, key_digest, window_seconds, window_started_at)
    DO UPDATE
    SET request_count = public_rate_limit_buckets.request_count + $6::bigint
    RETURNING request_count
  ),
  cleanup_summary AS (
    SELECT count(*) AS deleted_count
    FROM cleanup
  )
  SELECT
    incremented.request_count <= $3::bigint AS allowed,
    CASE
      WHEN incremented.request_count <= $3::bigint THEN 0
      ELSE greatest(
        1::bigint,
        current_window.ends_epoch - current_window.epoch_second
      )
    END AS retry_after
  FROM incremented
  CROSS JOIN current_window
  CROSS JOIN cleanup_summary
  """

  @type scope ::
          :instant_room_create
          | :instant_room_join
          | :instant_room_conversion
          | :instant_room_message
          | :instant_room_whiteboard
          | :direct_audio_join
          | :direct_audio_signal

  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @spec allow?(scope(), binary(), pos_integer(), pos_integer()) :: Decision.t()
  def allow?(scope, key_digest, limit, window_seconds)
      when scope in @scopes and is_binary(key_digest) and byte_size(key_digest) == 32 and
             is_integer(limit) and limit > 0 and is_integer(window_seconds) and
             window_seconds > 0 do
    allow?(scope, key_digest, limit, window_seconds, 1)
  end

  def allow?(_scope, _key_digest, _limit, _window_seconds), do: invalid_arguments!()

  @spec allow?(scope(), binary(), pos_integer(), pos_integer(), pos_integer()) :: Decision.t()
  def allow?(scope, key_digest, limit, window_seconds, cost)
      when scope in @scopes and is_binary(key_digest) and byte_size(key_digest) == 32 and
             is_integer(limit) and limit > 0 and is_integer(window_seconds) and
             window_seconds > 0 and is_integer(cost) and cost > 0 do
    case SQL.query!(
           Repo,
           @consume_sql,
           [
             Atom.to_string(scope),
             key_digest,
             limit,
             window_seconds,
             @cleanup_limit,
             cost
           ]
         ).rows do
      [[allowed, retry_after]]
      when is_boolean(allowed) and is_integer(retry_after) and retry_after >= 0 ->
        %Decision{allowed: allowed, retry_after: retry_after}

      rows ->
        raise "public rate limit query returned an invalid result: #{inspect(rows)}"
    end
  end

  def allow?(_scope, _key_digest, _limit, _window_seconds, _cost), do: invalid_arguments!()

  defp invalid_arguments! do
    raise ArgumentError,
          "platform rate limits require a supported scope, a 32-byte digest, " <>
            "and positive integer limit/window/cost values"
  end
end
