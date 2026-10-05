defmodule CommsWeb.EnterpriseAvailabilityControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Accounts.User
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  setup do
    owner = Fixtures.account_fixture()
    token = owner |> Fixtures.authentication_result() |> CommsWeb.Token.issue()
    %{owner: owner, token: token.access_token}
  end

  test "availability accepts the millisecond ISO deadline emitted by a browser", context do
    %{owner: owner, token: token} = context
    future = DateTime.add(DateTime.utc_now(), 1_800, :second)
    expected = %{future | microsecond: {588_000, 3}}

    response =
      authenticated_conn(token)
      |> put("/api/v1/me/availability", %{
        presence_state: "dnd",
        presence_expires_at: DateTime.to_iso8601(expected),
        dnd_until: nil,
        dnd_schedule: %{}
      })
      |> json_response(200)

    assert response["data"]["dnd_active"]
    assert response["data"]["status"] == "dnd"
    {:ok, returned, 0} = DateTime.from_iso8601(response["data"]["presence_expires_at"])
    assert DateTime.compare(returned, expected) == :eq
    assert returned.microsecond == {588_000, 6}
    assert DateTime.compare(Repo.get!(User, owner.user.id).presence_expires_at, expected) == :eq

    fetched = authenticated_conn(token) |> get("/api/v1/me/availability") |> json_response(200)
    assert fetched["data"]["presence_expires_at"] == response["data"]["presence_expires_at"]
    assert fetched["data"]["retry_at"] == response["data"]["presence_expires_at"]
  end

  test "six-digit DND timestamps remain exact and missing timezones cannot replace them",
       context do
    %{owner: owner, token: token} = context
    future = DateTime.add(DateTime.utc_now(), 1_800, :second)
    expected = %{future | microsecond: {588_321, 6}}

    response =
      authenticated_conn(token)
      |> put("/api/v1/me/availability", %{
        presence_state: "available",
        dnd_until: DateTime.to_iso8601(expected)
      })
      |> json_response(200)

    {:ok, returned, 0} = DateTime.from_iso8601(response["data"]["dnd_until"])
    assert DateTime.compare(returned, expected) == :eq
    assert returned.microsecond == {588_321, 6}

    authenticated_conn(token)
    |> put("/api/v1/me/availability", %{
      dnd_until: expected |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    })
    |> json_response(422)

    assert DateTime.compare(Repo.get!(User, owner.user.id).dnd_until, expected) == :eq
  end

  defp authenticated_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
end
