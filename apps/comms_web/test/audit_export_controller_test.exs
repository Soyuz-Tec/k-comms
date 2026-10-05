defmodule CommsWeb.AuditExportControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Audit

  test "authorized export downloads bounded CSV and records disposition metadata" do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-horse-audit-export-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Audit Export #{suffix}",
        tenant_slug: "audit-export-#{suffix}",
        display_name: "Audit Owner",
        email: "audit-owner-#{suffix}@example.test",
        password: password
      })
      |> json_response(201)

    token = bootstrap["access_token"]

    proof_required = authenticated_conn(token) |> post("/api/v1/admin/audit-events/export", %{})
    assert response(proof_required, 428)
    assert_private_response(proof_required)

    authenticated_conn(token)
    |> post("/api/v1/me/step-up", %{current_password: password})
    |> json_response(200)

    assert {:ok, _event} =
             Audit.record(%{
               tenant_id: bootstrap["tenant"]["id"],
               actor_user_id: bootstrap["user"]["id"],
               action: "=CMD()",
               resource_type: "+spreadsheet",
               resource_id: Ecto.UUID.generate(),
               request_id: "@request",
               metadata: %{}
             })

    conn =
      authenticated_conn(token)
      |> post("/api/v1/admin/audit-events/export", %{action: "=CMD()", limit: 10})

    assert response(conn, 200) =~ "\"'=CMD()\""
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^attachment; filename="k-comms-audit-[0-9TZ]+\.csv"$/
    assert get_resp_header(conn, "x-export-row-count") == ["1"]
    assert get_resp_header(conn, "x-export-truncated") == ["false"]
    assert_private_response(conn)

    malformed =
      authenticated_conn(token)
      |> post("/api/v1/admin/audit-events/export", %{after: "yesterday"})

    assert response(malformed, 422)
    assert_private_response(malformed)
  end

  test "current persisted role denial and authentication errors are never cacheable" do
    account = CommsTestSupport.Fixtures.account_fixture()
    CommsTestSupport.Fixtures.step_up(account)

    token =
      account
      |> CommsTestSupport.Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    account.user
    |> Ecto.Changeset.change(role: :member)
    |> CommsCore.Repo.update!()

    forbidden = authenticated_conn(token) |> post("/api/v1/admin/audit-events/export", %{})
    assert response(forbidden, 403)
    assert_private_response(forbidden)

    unauthenticated = build_conn() |> post("/api/v1/admin/audit-events/export", %{})
    assert response(unauthenticated, 401)
    assert_private_response(unauthenticated)

    invalid_token =
      authenticated_conn("invalid-synthetic-token")
      |> post("/api/v1/admin/audit-events/export", %{})

    assert response(invalid_token, 401)
    assert_private_response(invalid_token)
  end

  test "the actual acceptance error retains private headers before authentication" do
    {406, headers, _body} =
      assert_error_sent(406, fn ->
        build_conn()
        |> put_req_header("accept", "text/plain")
        |> post("/api/v1/admin/audit-events/export", %{})
      end)

    assert List.keyfind(headers, "cache-control", 0) == {"cache-control", "no-store"}
    assert List.keyfind(headers, "pragma", 0) == {"pragma", "no-cache"}
  end

  test "the existing identity rate limit refuses before export and retains private headers" do
    account = CommsTestSupport.Fixtures.account_fixture()

    token =
      account
      |> CommsTestSupport.Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    for _ <- 1..600 do
      assert CommsWeb.RateLimiter.allow?({:identity, account.user.id}, 600, 60)
    end

    limited = authenticated_conn(token) |> post("/api/v1/admin/audit-events/export", %{})
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(limited, 429)
    assert get_resp_header(limited, "retry-after") == ["60"]
    assert_private_response(limited)
    assert Audit.count(%{tenant_id: account.tenant.id, action: "audit.export"}) == 0
  end

  defp assert_private_response(conn) do
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp authenticated_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
