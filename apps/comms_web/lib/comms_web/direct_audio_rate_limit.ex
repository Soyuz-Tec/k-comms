defmodule CommsWeb.DirectAudioRateLimit do
  @moduledoc false

  alias CommsCore.PlatformRateLimits
  alias CommsWeb.Plugs.DistributedRateLimit

  @window_seconds 60

  def allow_join?(call_id, subject) when is_binary(call_id) and is_map(subject) do
    with {:ok, tenant_id} <- identifier(subject, :tenant_id),
         {:ok, user_id} <- identifier(subject, :user_id) do
      limit = configured_limit(:direct_audio_join_rate_limit, 8)

      decision =
        PlatformRateLimits.allow?(
          :direct_audio_join,
          digest(:direct_audio_join, [tenant_id, user_id, call_id]),
          limit,
          @window_seconds
        )

      if decision.allowed, do: :ok, else: {:error, :rate_limited}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def allow_join?(_call_id, _subject), do: {:error, :unauthorized}

  def allow_signal?(call_id, target_user_id, signal, subject)
      when is_binary(call_id) and is_binary(target_user_id) and is_map(signal) and
             is_map(subject) do
    with {:ok, tenant_id} <- identifier(subject, :tenant_id),
         {:ok, user_id} <- identifier(subject, :user_id),
         :ok <- consume_signal_count(tenant_id, user_id, call_id, target_user_id),
         :ok <- consume_signal_bytes(tenant_id, user_id, call_id, target_user_id, signal) do
      :ok
    else
      {:error, :rate_limited} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  def allow_signal?(_call_id, _target_user_id, _signal, _subject),
    do: {:error, :unauthorized}

  defp consume_signal_count(tenant_id, user_id, call_id, target_user_id) do
    decision =
      PlatformRateLimits.allow?(
        :direct_audio_signal,
        digest(:direct_audio_signal, ["messages", tenant_id, user_id, call_id, target_user_id]),
        configured_limit(:direct_audio_signal_rate_limit, 240),
        @window_seconds
      )

    if decision.allowed, do: :ok, else: {:error, :rate_limited}
  end

  defp consume_signal_bytes(tenant_id, user_id, call_id, target_user_id, signal) do
    bytes = signal |> Jason.encode_to_iodata!() |> IO.iodata_length()

    decision =
      PlatformRateLimits.allow?(
        :direct_audio_signal,
        digest(:direct_audio_signal, ["bytes", tenant_id, user_id, call_id, target_user_id]),
        configured_limit(:direct_audio_signal_byte_limit, 262_144),
        @window_seconds,
        max(bytes, 1)
      )

    if decision.allowed, do: :ok, else: {:error, :rate_limited}
  end

  defp digest(scope, identifiers) do
    material =
      identifiers
      |> Enum.map(&length_prefixed/1)
      |> Enum.intersperse(<<0>>)

    DistributedRateLimit.key_digest(scope, material)
  end

  defp identifier(subject, key) do
    case Map.get(subject, key) || Map.get(subject, Atom.to_string(key)) do
      value when is_binary(value) and byte_size(value) in 1..128 -> {:ok, value}
      _ -> :error
    end
  end

  defp length_prefixed(value) when is_binary(value) and byte_size(value) <= 65_535,
    do: [<<byte_size(value)::unsigned-big-16>>, value]

  defp configured_limit(key, default) do
    case Application.get_env(:comms_web, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
