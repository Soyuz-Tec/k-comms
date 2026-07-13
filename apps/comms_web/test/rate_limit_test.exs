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

  test "service and password admission buckets do not consume each other's capacity" do
    remote_ip = {198, 51, 100, 201}
    conn = %{build_conn() | remote_ip: remote_ip}

    service = RateLimit.call(conn, limit: 1, window: 60, scope: :service_authentication_ip)
    password_ip = RateLimit.call(conn, limit: 1, window: 60, scope: :password_verification_ip)

    password_identity =
      conn
      |> Plug.Conn.assign(:current_subject, %{user_id: "rate-limit-user"})
      |> RateLimit.call(limit: 1, window: 60, scope: :password_verification_identity)

    refute service.halted
    refute password_ip.halted
    refute password_identity.halted

    assert RateLimit.call(conn,
             limit: 1,
             window: 60,
             scope: :service_authentication_ip
           ).halted
  end

  test "password verification stops a credential-guessing burst after five attempts" do
    suffix = System.unique_integer([:positive, :monotonic])

    session =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Verifier Limit #{suffix}",
        tenant_slug: "verifier-limit-#{suffix}",
        display_name: "Verifier Owner",
        email: "verifier-limit-#{suffix}@example.test",
        password: "correct-horse-verifier-limit-#{suffix}"
      })
      |> json_response(201)

    for _attempt <- 1..5 do
      assert authenticated_conn(session["access_token"])
             |> post("/api/v1/me/step-up", %{current_password: "wrong-password"})
             |> response(401)
    end

    response =
      authenticated_conn(session["access_token"])
      |> post("/api/v1/me/step-up", %{current_password: "wrong-password"})
      |> json_response(429)

    assert response["error"]["code"] == "rate_limited"
  end

  test "service authentication rejects a shaped invalid-credential burst before further DB auth" do
    remote_ip = {198, 51, 100, 202}

    credential =
      "kcsa_#{Ecto.UUID.generate()}.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"

    for _attempt <- 1..600 do
      assert remote_ip
             |> service_conn(credential)
             |> get("/api/v1/service/conversations")
             |> response(401)
    end

    response =
      remote_ip
      |> service_conn(credential)
      |> get("/api/v1/service/conversations")
      |> json_response(429)

    assert response["error"]["code"] == "rate_limited"
  end

  defp recovery_conn(remote_ip, email) do
    %{
      build_conn()
      | remote_ip: remote_ip,
        params: %{"tenant_slug" => "rotating", "email" => email}
    }
  end

  defp authenticated_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp service_conn(remote_ip, credential) do
    conn = build_conn() |> put_req_header("authorization", "Bearer #{credential}")
    %{conn | remote_ip: remote_ip}
  end
end
