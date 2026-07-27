defmodule CommsWeb.OptionalHumanAuthenticationTest do
  use CommsWeb.ConnCase, async: false

  alias CommsTestSupport.Fixtures

  test "the absence of Authorization remains anonymous", %{conn: conn} do
    conn = CommsWeb.Plugs.OptionalHumanAuthentication.call(conn, [])

    refute conn.halted
    assert conn.assigns.current_subject == nil
  end

  test "a valid human bearer is assigned", %{conn: conn} do
    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> CommsWeb.Plugs.OptionalHumanAuthentication.call([])

    refute conn.halted
    assert conn.assigns.current_subject.user_id == account.user.id
    assert conn.assigns.current_user.account_type == :human
  end

  test "invalid, non-Bearer, and duplicate credentials never downgrade to anonymous" do
    guest_scoped_token =
      Phoenix.Token.sign(CommsWeb.Endpoint, "k-comms-guest-access-v1", %{
        "session_id" => Ecto.UUID.generate(),
        "conversation_id" => Ecto.UUID.generate(),
        "admission_id" => Ecto.UUID.generate()
      })

    for headers <- [
          ["Bearer invalid"],
          ["Bearer #{guest_scoped_token}"],
          ["Basic invalid"],
          ["Bearer invalid", "Bearer another"]
        ] do
      rejected =
        Enum.reduce(headers, build_conn(), fn value, request ->
          prepend_req_headers(request, [{"authorization", value}])
        end)
        |> CommsWeb.Plugs.OptionalHumanAuthentication.call([])

      assert rejected.halted
      assert rejected.status == 401
      assert Jason.decode!(rejected.resp_body)["error"]["code"] == "unauthenticated"
    end
  end
end
