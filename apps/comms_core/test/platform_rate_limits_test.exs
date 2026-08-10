defmodule CommsCore.PlatformRateLimitsTest do
  use ExUnit.Case, async: false

  alias CommsCore.PlatformRateLimits
  alias CommsCore.PlatformRateLimits.Decision
  alias CommsCore.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    delete_all_buckets()
    on_exit(&delete_all_buckets/0)
  end

  test "atomically enforces one limit across concurrent database connections" do
    parent = self()
    release_ref = make_ref()
    digest = digest("concurrent-public-mutation")
    attempts = 24
    limit = 7

    tasks =
      for _attempt <- 1..attempts do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            {:start, ^release_ref} ->
              unboxed(fn ->
                [[backend_pid]] =
                  SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows

                decision =
                  PlatformRateLimits.allow?(:instant_room_create, digest, limit, 600)

                {backend_pid, decision}
              end)
          after
            5_000 -> raise "rate limit concurrency barrier timed out"
          end
        end)
      end

    ready_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:ready, pid}, 5_000
        pid
      end)

    assert MapSet.new(ready_pids) == MapSet.new(tasks, & &1.pid)

    Enum.each(tasks, &send(&1.pid, {:start, release_ref}))
    results = Task.await_many(tasks, 15_000)
    {backend_pids, decisions} = Enum.unzip(results)

    assert backend_pids |> Enum.uniq() |> length() > 1
    assert Enum.count(decisions, & &1.allowed) == limit
    assert Enum.count(decisions, &(not &1.allowed)) == attempts - limit
    assert Enum.all?(Enum.filter(decisions, & &1.allowed), &(&1.retry_after == 0))

    assert Enum.all?(
             Enum.reject(decisions, & &1.allowed),
             &(&1.retry_after in 1..600)
           )

    assert [[^attempts]] =
             unboxed(fn ->
               SQL.query!(
                 Repo,
                 """
                 SELECT request_count
                 FROM public_rate_limit_buckets
                 WHERE scope = 'instant_room_create' AND key_digest = $1
                 """,
                 [digest]
               ).rows
             end)
  end

  test "keeps each supported public mutation scope independent" do
    digest = digest("shared-client")

    for scope <- PlatformRateLimits.scopes() do
      assert %Decision{allowed: true, retry_after: 0} =
               unboxed(fn -> PlatformRateLimits.allow?(scope, digest, 1, 600) end)
    end

    for scope <- PlatformRateLimits.scopes() do
      assert %Decision{allowed: false, retry_after: retry_after} =
               unboxed(fn -> PlatformRateLimits.allow?(scope, digest, 1, 600) end)

      assert retry_after in 1..600
    end
  end

  test "keeps simultaneous policies with different windows independent" do
    digest = digest("multi-window-client")

    assert %Decision{allowed: true} =
             unboxed(fn ->
               PlatformRateLimits.allow?(:instant_room_create, digest, 1, 60)
             end)

    assert %Decision{allowed: true} =
             unboxed(fn ->
               PlatformRateLimits.allow?(:instant_room_create, digest, 1, 86_400)
             end)

    assert [[60], [86_400]] =
             unboxed(fn ->
               SQL.query!(
                 Repo,
                 """
                 SELECT window_seconds
                 FROM public_rate_limit_buckets
                 WHERE scope = 'instant_room_create' AND key_digest = $1
                 ORDER BY window_seconds
                 """,
                 [digest]
               ).rows
             end)
  end

  test "charges weighted byte costs atomically" do
    digest = digest("weighted-direct-audio-signal")

    assert %Decision{allowed: true} =
             unboxed(fn ->
               PlatformRateLimits.allow?(:direct_audio_signal, digest, 10, 600, 7)
             end)

    assert %Decision{allowed: false} =
             unboxed(fn ->
               PlatformRateLimits.allow?(:direct_audio_signal, digest, 10, 600, 4)
             end)

    assert [[11]] =
             unboxed(fn ->
               SQL.query!(
                 Repo,
                 "SELECT request_count FROM public_rate_limit_buckets WHERE key_digest = $1",
                 [digest]
               ).rows
             end)
  end

  test "rejects raw or malformed keys before they reach PostgreSQL" do
    assert_raise ArgumentError, fn ->
      PlatformRateLimits.allow?(:instant_room_join, "203.0.113.42", 10, 60)
    end

    assert_raise ArgumentError, fn ->
      PlatformRateLimits.allow?(
        :instant_room_join,
        "guest-secret-token-that-must-not-persist",
        10,
        60
      )
    end

    assert_raise ArgumentError, fn ->
      PlatformRateLimits.allow?(:unsupported, digest("opaque"), 10, 60)
    end

    assert_raise ArgumentError, fn ->
      PlatformRateLimits.allow?(:direct_audio_signal, digest("opaque"), 10, 60, 0)
    end

    assert [[0]] =
             unboxed(fn ->
               SQL.query!(Repo, "SELECT count(*) FROM public_rate_limit_buckets", []).rows
             end)
  end

  test "deletes at most one bounded batch of expired buckets per decision" do
    unboxed(fn ->
      SQL.query!(
        Repo,
        """
        INSERT INTO public_rate_limit_buckets (
          scope,
          key_digest,
          window_seconds,
          window_started_at,
          request_count,
          expires_at
        )
        SELECT
          'instant_room_create',
          decode(lpad(to_hex(value), 64, '0'), 'hex'),
          60,
          timezone('UTC', clock_timestamp()) - interval '2 minutes',
          1,
          timezone('UTC', clock_timestamp()) - interval '1 minute'
        FROM generate_series(1, 105) AS value
        """,
        []
      )
    end)

    assert %{allowed: true} =
             unboxed(fn ->
               PlatformRateLimits.allow?(
                 :instant_room_message,
                 digest("cleanup-trigger"),
                 1,
                 600
               )
             end)

    assert [[5]] =
             unboxed(fn ->
               SQL.query!(
                 Repo,
                 """
                 SELECT count(*)
                 FROM public_rate_limit_buckets
                 WHERE expires_at <= timezone('UTC', clock_timestamp())
                 """,
                 []
               ).rows
             end)
  end

  defp delete_all_buckets do
    unboxed(fn ->
      SQL.query!(Repo, "DELETE FROM public_rate_limit_buckets", [])
    end)
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
