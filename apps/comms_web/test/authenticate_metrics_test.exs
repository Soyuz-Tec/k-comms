defmodule CommsWeb.AuthenticateMetricsTest do
  use ExUnit.Case, async: false

  alias CommsWeb.Plugs.AuthenticateMetrics

  setup do
    previous_token = Application.get_env(:comms_web, :metrics_bearer_token)
    previous_allow = Application.get_env(:comms_web, :metrics_allow_unauthenticated)

    on_exit(fn ->
      restore(:metrics_bearer_token, previous_token)
      restore(:metrics_allow_unauthenticated, previous_allow)
    end)

    :ok
  end

  test "fails closed when no scraper credential is configured" do
    Application.delete_env(:comms_web, :metrics_bearer_token)
    Application.put_env(:comms_web, :metrics_allow_unauthenticated, false)

    conn = Plug.Test.conn(:get, "/metrics") |> AuthenticateMetrics.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "accepts only the configured bearer token" do
    token = String.duplicate("a", 48)
    Application.put_env(:comms_web, :metrics_bearer_token, token)
    Application.put_env(:comms_web, :metrics_allow_unauthenticated, false)

    rejected =
      Plug.Test.conn(:get, "/metrics")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{String.duplicate("b", 48)}")
      |> AuthenticateMetrics.call([])

    accepted =
      Plug.Test.conn(:get, "/metrics")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> AuthenticateMetrics.call([])

    assert rejected.status == 401
    refute accepted.halted
  end

  defp restore(key, nil), do: Application.delete_env(:comms_web, key)
  defp restore(key, value), do: Application.put_env(:comms_web, key, value)
end
