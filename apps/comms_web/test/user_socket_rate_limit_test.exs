defmodule CommsWeb.UserSocketRateLimitTest.CaptureAuth do
  @behaviour CommsWeb.Auth

  @impl true
  def authenticate(_params, _connect_info) do
    send(Application.fetch_env!(:comms_web, :socket_rate_limit_test_pid), :socket_auth_attempt)
    {:error, :unauthenticated}
  end
end

defmodule CommsWeb.UserSocketRateLimitTest do
  use CommsWeb.ConnCase, async: false

  alias CommsWeb.UserSocket

  setup do
    previous_adapter = Application.get_env(:comms_web, :auth_adapter)
    previous_pid = Application.get_env(:comms_web, :socket_rate_limit_test_pid)
    previous_proxies = Application.get_env(:comms_web, :trusted_proxy_cidrs)

    Application.put_env(
      :comms_web,
      :auth_adapter,
      CommsWeb.UserSocketRateLimitTest.CaptureAuth
    )

    Application.put_env(:comms_web, :socket_rate_limit_test_pid, self())

    on_exit(fn ->
      restore(:auth_adapter, previous_adapter)
      restore(:socket_rate_limit_test_pid, previous_pid)
      restore(:trusted_proxy_cidrs, previous_proxies)
    end)

    :ok
  end

  test "an untrusted peer cannot rotate forwarded headers around socket admission" do
    Application.put_env(:comms_web, :trusted_proxy_cidrs, ["10.0.0.0/8"])

    Enum.each(1..61, fn index ->
      connect_info = %{
        peer_data: %{address: {198, 51, 100, 25}},
        x_headers: [{"x-forwarded-for", "203.0.113.#{index}"}]
      }

      assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, connect_info)
    end)

    assert auth_attempts() == 60
  end

  test "a trusted ingress uses the right-most untrusted client and ignores prepended spoofing" do
    Application.put_env(:comms_web, :trusted_proxy_cidrs, ["10.0.0.0/8"])

    Enum.each(1..61, fn index ->
      connect_info = %{
        peer_data: %{address: {10, 0, 0, 5}},
        x_headers: [
          {"x-forwarded-for", "198.51.100.#{index}, 203.0.113.9, 10.0.0.4"}
        ]
      }

      assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, connect_info)
    end)

    assert auth_attempts() == 60

    assert :error =
             UserSocket.connect(%{}, %Phoenix.Socket{}, %{
               peer_data: %{address: {10, 0, 0, 5}},
               x_headers: [{"x-forwarded-for", "203.0.113.10, 10.0.0.4"}]
             })

    assert auth_attempts() == 1
  end

  test "a direct peer is admitted by its socket address before ticket authentication" do
    Application.put_env(:comms_web, :trusted_proxy_cidrs, [])
    connect_info = %{peer_data: %{address: {203, 0, 113, 44}}}

    Enum.each(1..61, fn _index ->
      assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, connect_info)
    end)

    assert auth_attempts() == 60
  end

  defp auth_attempts(count \\ 0) do
    receive do
      :socket_auth_attempt -> auth_attempts(count + 1)
    after
      0 -> count
    end
  end

  defp restore(key, nil), do: Application.delete_env(:comms_web, key)
  defp restore(key, value), do: Application.put_env(:comms_web, key, value)
end
