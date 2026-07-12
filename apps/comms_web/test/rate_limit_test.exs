defmodule CommsWeb.RateLimitTest do
  use CommsWeb.ConnCase, async: false

  alias CommsWeb.Plugs.RateLimit

  test "IP-wide authentication limit cannot be bypassed by rotating account identifiers" do
    suffix = rem(System.unique_integer([:positive, :monotonic]), 200) + 20
    remote_ip = {198, 51, 100, suffix}

    first =
      remote_ip
      |> recovery_conn("one@example.test")
      |> RateLimit.call(limit: 2, window: 60, scope: :authentication_ip)

    second =
      remote_ip
      |> recovery_conn("two@example.test")
      |> RateLimit.call(limit: 2, window: 60, scope: :authentication_ip)

    third =
      remote_ip
      |> recovery_conn("three@example.test")
      |> RateLimit.call(limit: 2, window: 60, scope: :authentication_ip)

    refute first.halted
    refute second.halted
    assert third.halted
    assert third.status == 429
    assert Jason.decode!(third.resp_body)["error"]["code"] == "rate_limited"
  end

  defp recovery_conn(remote_ip, email) do
    %{
      build_conn()
      | remote_ip: remote_ip,
        params: %{"tenant_slug" => "rotating", "email" => email}
    }
  end
end
