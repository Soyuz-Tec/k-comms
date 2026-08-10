defmodule CommsWeb.EndpointSecurityConfigTest do
  use ExUnit.Case, async: true

  test "caps Phoenix and Bandit WebSocket messages at one MiB" do
    assert CommsWeb.Endpoint.websocket_max_frame_size() == 1_048_576

    http =
      :comms_web
      |> Application.fetch_env!(CommsWeb.Endpoint)
      |> Keyword.fetch!(:http)

    websocket_options = Keyword.fetch!(http, :websocket_options)
    assert Keyword.fetch!(websocket_options, :max_frame_size) == 1_048_576
    assert Keyword.fetch!(websocket_options, :max_fragmented_message_size) == 1_048_576
  end
end
