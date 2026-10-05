defmodule CommsWeb.SharedDocumentControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.Accounts
  alias CommsTestSupport.Fixtures

  setup do
    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    %{account: account, token: token}
  end

  test "real HTTP creation, operation receipts, replay and plaintext export retain private headers",
       context do
    path = "/api/v1/conversations/#{context.account.conversation.id}/documents"

    created =
      conn(context)
      |> post(path, %{client_document_id: Ecto.UUID.generate(), title: "HTTP notes"})
      |> json_response(201)

    id = created["data"]["id"]

    input = %{
      client_operation_id: Ecto.UUID.generate(),
      generation: 1,
      base_version: 1,
      kind: "edit",
      changes: [%{after_id: nil, delete_ids: [], insert: "Current authorized phrase 😀"}]
    }

    response = conn(context) |> post("/api/v1/documents/#{id}/operations", input)
    operation = json_response(response, 201)["data"]
    assert operation["version"] == 2
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "pragma") == ["no-cache"]

    assert conn(context)
           |> post("/api/v1/documents/#{id}/operations", input)
           |> json_response(200)
           |> Map.fetch!("data") == operation

    replay =
      conn(context)
      |> get("/api/v1/documents/#{id}/operations?generation=1&after_version=1&limit=1")
      |> json_response(200)

    assert replay["data"] == [operation]
    export = conn(context) |> get("/api/v1/documents/#{id}/export")
    assert response(export, 200) == "HTTP notes\n\nCurrent authorized phrase 😀"
    assert get_resp_header(export, "x-document-version") == ["2"]
    assert get_resp_header(export, "x-document-generation") == ["1"]
    assert get_resp_header(export, "cache-control") == ["no-store"]

    summary =
      conn(context)
      |> get(path <> "?q=phrase")
      |> json_response(200)
      |> Map.fetch!("data")
      |> hd()

    refute Map.has_key?(summary, "atoms")
    refute Map.has_key?(summary, "author_user_ids")
  end

  test "forged graphs, unknown atoms and invalid replay windows fail through actual fallback",
       context do
    created =
      conn(context)
      |> post("/api/v1/conversations/#{context.account.conversation.id}/documents", %{
        client_document_id: Ecto.UUID.generate(),
        title: "Invalid input"
      })
      |> json_response(201)

    id = created["data"]["id"]

    input = %{
      client_operation_id: Ecto.UUID.generate(),
      generation: 1,
      base_version: 1,
      kind: "edit",
      changes: [%{after_id: Ecto.UUID.generate() <> ":0", delete_ids: [], insert: "forged"}]
    }

    assert conn(context)
           |> post("/api/v1/documents/#{id}/operations", input)
           |> json_response(422)
           |> get_in(["error", "code"]) == "unknown_document_atom"

    assert conn(context)
           |> get("/api/v1/documents/#{id}/operations?generation=1&limit=101")
           |> json_response(422)

    assert conn(context)
           |> get("/api/v1/documents/#{id}/operations?generation=2")
           |> json_response(409)
           |> get_in(["error", "code"]) == "stale_document_generation"
  end

  test "session revocation prevents current snapshots, replay, copies and exports", context do
    created =
      conn(context)
      |> post("/api/v1/conversations/#{context.account.conversation.id}/documents", %{
        client_document_id: Ecto.UUID.generate(),
        title: "Revoked content"
      })
      |> json_response(201)

    id = created["data"]["id"]

    assert :ok =
             Accounts.revoke_session(
               context.account.session.id,
               Fixtures.subject(context.account)
             )

    for path <- [
          "/api/v1/documents/#{id}",
          "/api/v1/documents/#{id}/export",
          "/api/v1/documents/#{id}/operations?generation=1"
        ] do
      rejected = conn(context) |> get(path)
      assert json_response(rejected, 401)["error"]["code"] == "unauthenticated"
      assert get_resp_header(rejected, "cache-control") == ["no-store"]
    end
  end

  defp conn(context),
    do: build_conn() |> put_req_header("authorization", "Bearer #{context.token}")
end
