defmodule CommsWeb.DirectAudioRateLimitTest do
  use ExUnit.Case, async: false

  alias CommsCore.Repo
  alias CommsWeb.DirectAudioRateLimit
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    previous_join = Application.get_env(:comms_web, :direct_audio_join_rate_limit)
    previous_signal = Application.get_env(:comms_web, :direct_audio_signal_rate_limit)
    previous_bytes = Application.get_env(:comms_web, :direct_audio_signal_byte_limit)
    delete_direct_buckets()

    on_exit(fn ->
      restore_env(:direct_audio_join_rate_limit, previous_join)
      restore_env(:direct_audio_signal_rate_limit, previous_signal)
      restore_env(:direct_audio_signal_byte_limit, previous_bytes)
      delete_direct_buckets()
      Sandbox.stop_owner(owner)
    end)

    :ok
  end

  test "aggregates join admission across sessions and nodes by actor and call" do
    Application.put_env(:comms_web, :direct_audio_join_rate_limit, 1)
    subject = %{tenant_id: "tenant-1", user_id: "user-1", session_id: "session-a"}

    assert :ok = DirectAudioRateLimit.allow_join?("call-1", subject)

    assert {:error, :rate_limited} =
             DirectAudioRateLimit.allow_join?("call-1", %{subject | session_id: "session-b"})

    assert :ok =
             DirectAudioRateLimit.allow_join?("call-2", %{subject | session_id: "session-c"})
  end

  test "enforces a distributed byte budget independently of message count" do
    signal = %{kind: "fallback"}
    signal_bytes = signal |> Jason.encode_to_iodata!() |> IO.iodata_length()
    Application.put_env(:comms_web, :direct_audio_signal_rate_limit, 10)
    Application.put_env(:comms_web, :direct_audio_signal_byte_limit, signal_bytes)
    subject = %{tenant_id: "tenant-1", user_id: "user-1", session_id: "session-a"}

    assert :ok = DirectAudioRateLimit.allow_signal?("call-1", "user-2", signal, subject)

    assert {:error, :rate_limited} =
             DirectAudioRateLimit.allow_signal?(
               "call-1",
               "user-2",
               signal,
               %{subject | session_id: "session-b"}
             )
  end

  defp delete_direct_buckets do
    SQL.query!(
      Repo,
      "DELETE FROM public_rate_limit_buckets WHERE scope IN ('direct_audio_join', 'direct_audio_signal')",
      []
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:comms_web, key)
  defp restore_env(key, value), do: Application.put_env(:comms_web, key, value)
end
