defmodule CommsWeb.DeletionRequestHistoryControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Accounts, Governance}
  alias CommsTestSupport.Fixtures

  setup do
    previous = Application.get_env(:comms_core, :governance_history_cursor_key)

    Application.put_env(
      :comms_core,
      :governance_history_cursor_key,
      "synthetic-web-history-key-only-32-bytes"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :governance_history_cursor_key, previous),
        else: Application.delete_env(:comms_core, :governance_history_cursor_key)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    target = Fixtures.user_fixture(account)

    {:ok, result} =
      Governance.create_deletion_request(
        %{
          target_type: "user",
          subject_user_id: target.user.id,
          reason: "Synthetic Web history request"
        },
        subject
      )

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    %{account: account, subject: subject, request: result.request, token: token}
  end

  test "JSON timeline exposes typed retained coverage and neutral fixed CSV disposition", ctx do
    conn = auth(ctx.token) |> get("/api/v1/admin/deletion-requests/#{ctx.request.id}/timeline")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    timeline = json_response(conn, 200)["data"]
    assert timeline["request"]["id"] == ctx.request.id

    assert [%{"action" => "deletion_request.create", "actor" => %{"kind" => "user"}}] =
             timeline["events"]

    assert timeline["coverage"]["retained_only"]
    assert timeline["coverage"]["maximum_events"] == 5_000

    conn =
      auth(ctx.token)
      |> get(
        "/api/v1/admin/deletion-requests/#{ctx.request.id}/timeline/export",
        %{snapshot: timeline["snapshot"]}
      )

    assert response(conn, 200) =~ "deletion_request.create"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="deletion-request-history.csv")
           ]

    assert get_resp_header(conn, "x-export-row-count") == ["1"]
    assert get_resp_header(conn, "x-export-truncated") == ["false"]
    assert get_resp_header(conn, "x-export-maximum-rows") == ["5000"]
    assert get_resp_header(conn, "x-history-snapshot") == [timeline["snapshot"]]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "invalid history inputs fail with explicit codes and no-store", ctx do
    for {params, code} <- [
          {%{cursor: "tampered"}, "invalid_history_cursor"},
          {%{limit: 51}, "invalid_history_limit"}
        ] do
      conn =
        auth(ctx.token)
        |> get("/api/v1/admin/deletion-requests/#{ctx.request.id}/timeline", params)

      assert json_response(conn, 422)["error"]["code"] == code
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    Application.delete_env(:comms_core, :governance_history_cursor_key)
    conn = auth(ctx.token) |> get("/api/v1/admin/deletion-requests/#{ctx.request.id}/timeline")
    assert json_response(conn, 503)["error"]["code"] == "history_unavailable"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "authorized origins may read export metadata, and fresh verification is required", ctx do
    previous = Application.get_env(:comms_web, :cors_origins)
    Application.put_env(:comms_web, :cors_origins, ["https://synthetic-history.example.test"])
    on_exit(fn -> Application.put_env(:comms_web, :cors_origins, previous || []) end)

    conn =
      auth(ctx.token)
      |> put_req_header("origin", "https://synthetic-history.example.test")
      |> get("/api/v1/admin/deletion-requests/#{ctx.request.id}/timeline/export")

    assert response(conn, 200)
    assert [exposed] = get_resp_header(conn, "access-control-expose-headers")

    for header <- ~w(x-history-snapshot x-history-coverage x-export-truncated x-export-row-count),
        do: assert(exposed =~ header)

    assert {:ok, _} = Accounts.revoke_session(ctx.account.session.id, ctx.account.user.id)

    assert auth(ctx.token)
           |> get("/api/v1/admin/deletion-requests/#{ctx.request.id}/timeline")
           |> response(401)
  end

  defp auth(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
