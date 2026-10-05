defmodule CommsWeb.MeetingControllerTest do
  use CommsWeb.ConnCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsTestSupport.Fixtures

  test "HTTP schedule, timezone-safe invitation, version conflict and cancellation use real owner commands" do
    account = Fixtures.account_fixture()
    conn = authenticated(account)

    meeting =
      conn
      |> post("/api/v1/conversations/#{account.conversation.id}/meetings", input())
      |> json_response(201)
      |> Map.fetch!("data")

    assert meeting["status"] == "scheduled"
    assert meeting["version"] == 1
    assert meeting["timezone"] == "Etc/UTC"
    assert length(meeting["occurrences"]) == 2

    list = authenticated(account) |> get("/api/v1/meetings") |> json_response(200)
    assert [%{"id" => id}] = list["data"]
    assert id == meeting["id"]
    assert list["meta"]["calendar"] == %{"ics" => true, "google" => false, "microsoft" => false}

    invitation =
      authenticated(account) |> get("/api/v1/meetings/#{id}/calendar") |> json_response(200)

    assert invitation["data"]["ics"] =~ "BEGIN:VCALENDAR"
    refute invitation["data"]["ics"] =~ "Bearer"

    response =
      authenticated(account)
      |> patch("/api/v1/meetings/#{id}", Map.put(input(), :expected_version, 3))
      |> json_response(409)

    assert response["error"]["code"] == "stale_version"

    cancelled =
      authenticated(account)
      |> post("/api/v1/meetings/#{id}/cancel", %{expected_version: 1})
      |> json_response(200)

    assert cancelled["data"]["status"] == "cancelled"
    assert cancelled["data"]["version"] == 2

    calendar =
      authenticated(account) |> get("/api/v1/meetings/#{id}/calendar") |> json_response(200)

    assert calendar["data"]["ics"] =~ "METHOD:CANCEL"
  end

  test "HTTP rejects foreign schedules and unbounded recurrence without persistence leaks" do
    account = Fixtures.account_fixture()
    other = Fixtures.account_fixture()

    meeting =
      authenticated(account)
      |> post("/api/v1/conversations/#{account.conversation.id}/meetings", input())
      |> json_response(201)

    id = meeting["data"]["id"]

    response =
      authenticated(other) |> get("/api/v1/meetings/#{id}/calendar") |> json_response(404)

    assert response["error"]["code"] == "not_found"
    invalid = Map.put(input(), :recurrence, %{frequency: "weekly", interval: 1, count: 53})

    error =
      authenticated(account)
      |> post("/api/v1/conversations/#{account.conversation.id}/meetings", invalid)
      |> json_response(422)

    assert error["error"]["code"] == "invalid_meeting_recurrence"
    refute inspect(error) =~ "Ecto.Changeset"
  end

  defp authenticated(account) do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp input do
    local =
      DateTime.utc_now()
      |> DateTime.add(3600)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)

    %{
      title: "HTTP planning",
      timezone: "Etc/UTC",
      local_start: NaiveDateTime.to_iso8601(local),
      duration_minutes: 60,
      reminder_minutes: 10,
      recurrence: %{frequency: "weekly", interval: 1, count: 2},
      host_policy: %{allow_guests: false, join_before_host: false}
    }
  end
end
