defmodule CommsIntegrations.Audio.LiveKitReadinessTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.Audio.LiveKitReadiness

  setup do
    values = %{
      audio_provider_mode: "livekit",
      livekit_server_url: "wss://audio.example.test",
      livekit_api_url: "https://audio-api.example.test",
      livekit_api_key: "test-api-key",
      livekit_api_secret: "test-api-secret",
      audio_token_ttl_seconds: 300
    }

    previous =
      Map.new(values, fn {key, _value} -> {key, Application.get_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_integrations, key),
          else: Application.put_env(:comms_integrations, key, value)
      end)
    end)

    :ok
  end

  test "uses a short room-list-only credential and returns no provider detail" do
    parent = self()

    requester = fn request ->
      send(parent, {:readiness_request, request})
      {:ok, %Finch.Response{status: 200, body: ~s({"rooms":[]})}}
    end

    assert :ok = LiveKitReadiness.check(requester)
    assert_receive {:readiness_request, request}
    assert request.method == "POST"
    assert request.scheme == :https
    assert request.host == "audio-api.example.test"
    assert request.path == "/twirp/livekit.RoomService/ListRooms"
    assert Jason.decode!(request.body) == %{}

    {"authorization", "Bearer " <> token} =
      Enum.find(request.headers, fn {name, _value} -> name == "authorization" end)

    [_header, encoded_claims, _signature] = String.split(token, ".")
    claims = encoded_claims |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert claims["exp"] - claims["nbf"] <= 35
    assert claims["video"] == %{"roomList" => true}
    refute Map.has_key?(claims, "sub")
    refute Map.has_key?(claims, "name")
  end

  test "caches a successful probe instead of issuing provider I/O on status reads" do
    parent = self()
    name = unique_name()

    start_supervised!(
      {LiveKitReadiness,
       name: name,
       interval_ms: 60_000,
       stale_after_ms: 60_000,
       probe: fn ->
         send(parent, :provider_probe)
         :ok
       end}
    )

    assert_receive :provider_probe
    assert eventually(fn -> LiveKitReadiness.status(name).status == :available end)

    Enum.each(1..10, fn _index ->
      assert LiveKitReadiness.status(name) == %{status: :available, adapter: :livekit}
    end)

    refute_receive :provider_probe, 50
  end

  test "fails closed quickly while a bounded provider probe times out" do
    parent = self()
    name = unique_name()

    start_supervised!(
      {LiveKitReadiness,
       name: name,
       interval_ms: 60_000,
       stale_after_ms: 60_000,
       timeout_ms: 20,
       probe: fn ->
         send(parent, :slow_probe)
         Process.sleep(200)
         :ok
       end}
    )

    assert_receive :slow_probe
    assert LiveKitReadiness.status(name).status == :unavailable

    assert eventually(fn ->
             LiveKitReadiness.status(name) == %{
               status: :unavailable,
               adapter: :livekit,
               reason: :probe_timeout
             }
           end)

    {elapsed_microseconds, status} = :timer.tc(fn -> LiveKitReadiness.status(name) end)
    assert status.status == :unavailable
    assert elapsed_microseconds < 50_000
  end

  test "rejects provider authentication failures without returning response content" do
    assert LiveKitReadiness.check(fn _request ->
             {:ok,
              %Finch.Response{
                status: 401,
                body: ~s({"error":"credential detail must not escape"})
              }}
           end) == {:error, :provider_rejected}
  end

  defp eventually(fun, attempts \\ 40)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp unique_name,
    do: String.to_atom("livekit_readiness_test_#{System.unique_integer([:positive])}")
end
