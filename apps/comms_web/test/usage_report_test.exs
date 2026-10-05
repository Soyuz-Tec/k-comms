defmodule CommsWeb.UsageReportTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Accounts, Repo}
  import Ecto.Query
  alias CommsCore.Accounts.{UsageQuery, User}
  alias CommsTestSupport.Fixtures
  alias CommsWeb.UsageReports
  @moduletag :integration

  test "HTTP JSON and CSV use identical inclusive UTC filters and observed receipts" do
    account = Fixtures.account_fixture()
    Fixtures.step_up(account)
    token = token(account)
    through = Date.utc_today() |> Date.to_iso8601()
    from = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    report =
      conn(token)
      |> get("/api/v1/admin/usage", %{from: from, through: through})
      |> json_response(200)

    assert report["data"]["range"] == %{"from" => from, "through" => through, "time_zone" => "UTC"}
    assert report["data"]["coverage"] == "currently_retained_records"
    refute report["data"]["lifetime_complete"]
    assert map_size(report["data"]["sources"]) == 6

    assert Enum.all?(report["data"]["sources"], fn {_key, source} ->
             source["status"] == "available" and length(source["data"]["daily"]) == 2
           end)

    assert report["data"]["sources"]["identity"]["data"]["current"]["active_humans"] == 1
    refute Jason.encode!(report) =~ account.user.email
    refute Jason.encode!(report) =~ account.user.id

    download = conn(token) |> get("/api/v1/admin/usage/export", %{from: from, through: through})
    assert download.status == 200
    assert get_resp_header(download, "x-usage-from") == [from]
    assert get_resp_header(download, "x-usage-through") == [through]
    assert get_resp_header(download, "x-usage-time-zone") == ["UTC"]
    assert get_resp_header(download, "x-usage-unavailable-sources") == ["0"]
    assert {:ok, _, 0} = DateTime.from_iso8601(hd(get_resp_header(download, "x-usage-observed-at")))
    assert download.resp_body =~ "\"identity\",\"available\",\"current\",\"active_humans\",\"1\""
    assert download.resp_body =~ "\"#{from}\",\"#{through}\",\"UTC\""
    refute download.resp_body =~ account.user.email
  end

  test "both endpoints deny non-admin, stale step-up, and limited elevated identities" do
    account = Fixtures.account_fixture()
    token = token(account)

    for path <- ["/api/v1/admin/usage", "/api/v1/admin/usage/export"] do
      response = conn(token) |> get(path) |> json_response(428)
      assert response["error"]["code"] == "step_up_required"
    end

    Fixtures.step_up(account)
    Repo.update_all(from(u in User, where: u.id == ^account.user.id), set: [role: :member])

    for path <- ["/api/v1/admin/usage", "/api/v1/admin/usage/export"] do
      assert (conn(token) |> get(path) |> json_response(403))["error"]["code"] == "forbidden"
    end

    Repo.update_all(from(u in User, where: u.id == ^account.user.id),
      set: [role: :owner, access_scope: :conversation_only]
    )

    for path <- ["/api/v1/admin/usage", "/api/v1/admin/usage/export"] do
      assert (conn(token) |> get(path) |> json_response(403))["error"]["code"] == "forbidden"
    end
  end

  test "allowed cross-origin CSV clients can inspect usage receipts while other origins expose none" do
    previous = Application.fetch_env(:comms_web, :cors_origins)
    origin = "https://synthetic-usage.example.test"
    Application.put_env(:comms_web, :cors_origins, [origin])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:comms_web, :cors_origins, value)
        :error -> Application.delete_env(:comms_web, :cors_origins)
      end
    end)

    account = Fixtures.account_fixture()
    Fixtures.step_up(account)
    token = token(account)
    today = Date.to_iso8601(Date.utc_today())

    download =
      conn(token)
      |> put_req_header("origin", origin)
      |> get("/api/v1/admin/usage/export", %{from: today, through: today})

    assert download.status == 200
    assert get_resp_header(download, "access-control-allow-origin") == [origin]
    assert get_resp_header(download, "access-control-allow-credentials") == ["true"]
    assert [exposed] = get_resp_header(download, "access-control-expose-headers")
    names = String.split(exposed, ",")

    for header <-
          ~w(x-usage-from x-usage-through x-usage-time-zone x-usage-observed-at x-usage-unavailable-sources) do
      assert header in names
      assert [_] = get_resp_header(download, header)
    end

    assert get_resp_header(download, "x-usage-from") == [today]
    assert get_resp_header(download, "x-usage-through") == [today]
    assert get_resp_header(download, "x-usage-time-zone") == ["UTC"]

    for retained <-
          ~w(content-disposition x-export-row-count x-export-truncated x-export-maximum-rows x-history-snapshot x-history-coverage x-history-retained-only x-history-observed-at),
        do: assert(retained in names)

    untrusted =
      conn(token)
      |> put_req_header("origin", "https://untrusted.example.test")
      |> get("/api/v1/admin/usage/export", %{from: today, through: today})

    assert untrusted.status == 200
    assert get_resp_header(untrusted, "access-control-allow-origin") == []
    assert get_resp_header(untrusted, "access-control-expose-headers") == []

    preflight =
      build_conn()
      |> put_req_header("origin", "https://untrusted.example.test")
      |> put_req_header("access-control-request-method", "GET")
      |> options("/api/v1/admin/usage/export")

    assert preflight.status == 403
    assert get_resp_header(preflight, "access-control-expose-headers") == []
  end

  test "ranges reject impossible, future, overlong, reversed, and extra filters" do
    account = Fixtures.account_fixture()
    Fixtures.step_up(account)
    token = token(account)
    today = Date.utc_today()

    invalid = [
      %{from: "2026-02-30", through: Date.to_iso8601(today)},
      %{from: Date.to_iso8601(Date.add(today, -31)), through: Date.to_iso8601(today)},
      %{from: Date.to_iso8601(today), through: Date.to_iso8601(Date.add(today, 1))},
      %{from: Date.to_iso8601(today), through: Date.to_iso8601(Date.add(today, -1))},
      %{user_id: account.user.id}
    ]

    for params <- invalid, path <- ["/api/v1/admin/usage", "/api/v1/admin/usage/export"] do
      assert (conn(token) |> get(path, params) |> json_response(422))["error"]["code"] ==
               "invalid_usage_query"
    end
  end

  test "a failed source is null while a successful empty projection is zero and later sources continue" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    sources = [
      {:calls, fn _, _ -> raise Postgrex.Error, message: "private failed query text" end},
      {:identity,
       fn range, subject ->
         Accounts.usage_projection(
           %UsageQuery{tenant_id: subject.tenant_id, from: range.from, through: range.through},
           subject
         )
       end},
      {:messages,
       fn range, _ ->
         {:ok,
          %CommsCore.Messaging.UsageProjection{
            observed_at: DateTime.utc_now(),
            earliest_retained_at: nil,
            current: %{retained_messages: 0},
            daily: [
              %{
                date: range.from,
                metrics: %{created: 0, current_active: 0, current_deleted: 0, current_moderated: 0}
              }
            ]
          }}
       end}
    ]

    today = Date.utc_today() |> Date.to_iso8601()

    assert {:ok, report} =
             UsageReports.collect(%{"from" => today, "through" => today}, subject, sources)

    assert report.sources.calls == %{status: "unavailable", data: nil}
    assert report.sources.identity.data.current.active_humans == 1
    assert report.sources.messages.data.current.retained_messages == 0
    assert {:ok, csv} = UsageReports.csv(report)
    assert csv =~ "\"calls\",\"unavailable\",\"\",\"\",\"\""
    assert csv =~ "\"messages\",\"available\",\"current\",\"retained_messages\",\"0\""
    refute csv =~ "private failed query text"
  end

  test "authorization changes cannot be disguised as an unavailable source" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:error, :forbidden} =
             UsageReports.collect(%{}, subject, [{:identity, fn _, _ -> {:error, :forbidden} end}])

    assert {:error, :step_up_required} =
             UsageReports.collect(%{}, subject, [
               {:calls, fn _, _ -> {:error, :step_up_required} end}
             ])

    assert {:ok, invalid} =
             UsageReports.collect(%{}, subject, [{:identity, fn _, _ -> {:ok, account.user} end}])

    assert invalid.sources.identity == %{status: "unavailable", data: nil}
    refute Jason.encode!(invalid) =~ account.user.email
  end

  test "CSV is bounded and escapes spreadsheet formulas and quoted cells" do
    now = DateTime.utc_now()

    source = %{
      status: "available",
      data: %{observed_at: now, earliest_retained_at: nil, current: %{active_humans: 1}, daily: []}
    }

    report = %{
      range: %{from: Date.utc_today(), through: Date.utc_today()},
      coverage: "=unsafe,\"cell\"",
      sources: %{identity: source}
    }

    assert {:ok, csv} = UsageReports.csv(report)
    assert csv =~ "\"'=unsafe,\"\"cell\"\"\""

    oversized =
      put_in(
        report,
        [:sources, :identity, :data, :daily],
        Enum.map(1..5000, fn _ -> %{date: Date.utc_today(), metrics: %{active_humans: 0}} end)
      )

    assert {:error, :usage_report_too_large} = UsageReports.csv(oversized)
  end

  defp token(account),
    do:
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

  defp conn(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
