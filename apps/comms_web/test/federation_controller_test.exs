defmodule CommsWeb.FederationControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Conversations.Federation.Trust
  alias CommsTestSupport.Fixtures

  test "actual authenticated routes return private metadata and keep providers disabled" do
    account = Fixtures.account_fixture()
    path = "/api/v1/conversations/#{account.conversation.id}/federation"
    conn = auth(account) |> get(path)
    assert json_response(conn, 200) == %{"data" => nil}
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert build_conn() |> get(path) |> response(401)

    response =
      auth(account)
      |> post(path, %{domain: "remote.example.org", plaintext_disclosure_accepted: true})

    assert json_response(response, 503)["error"]["code"] == "federation_disabled"
    refute Repo.exists?(Trust)
  end

  test "the actual admin policy endpoint verifies the retained owner session" do
    account = Fixtures.account_fixture()

    attrs = %{
      domain: "remote.example.org",
      residency: "Synthetic region",
      cross_border_reason: "Reviewed synthetic processing",
      enabled: true
    }

    denied = auth(account) |> put("/api/v1/admin/federation/trusts", attrs)
    assert json_response(denied, 428)["error"]["code"] == "step_up_required"
    assert get_resp_header(denied, "cache-control") == ["private, no-store"]
    Fixtures.step_up(account)
    saved = auth(account) |> put("/api/v1/admin/federation/trusts", attrs) |> json_response(200)
    assert saved["data"]["residency_verified"] == false

    assert Enum.sort(Map.keys(saved["data"])) ==
             ~w(cross_border_reason domain enabled id residency residency_verified version)

    assert {:ok, trusts} = Conversations.federation_trusts(Fixtures.subject(account))
    assert length(trusts) == 1
  end

  test "a foreign tenant cannot read another conversation's bridge or invite its principals" do
    account = Fixtures.account_fixture()
    foreign = Fixtures.account_fixture()
    path = "/api/v1/conversations/#{account.conversation.id}/federation"
    assert auth(foreign) |> get(path) |> response(403)

    response =
      auth(foreign)
      |> post(path <> "/invitations", %{version: 1, matrix_user_id: "@person:remote.example.org"})

    assert json_response(response, 503)["error"]["code"] == "federation_disabled"
    refute Repo.exists?(Trust)
  end

  defp auth(account) do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end
end
