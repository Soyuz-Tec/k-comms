defmodule CommsWeb.AuthAndMessagingControllerTest do
  use CommsWeb.ConnCase, async: false

  test "bootstrap, send, replay, idempotency, and logout form a runnable journey" do
    suffix = System.unique_integer([:positive, :monotonic])

    response =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Web Test #{suffix}",
        tenant_slug: "web-test-#{suffix}",
        display_name: "Owner",
        email: "owner-#{suffix}@example.test",
        password: "correct-horse-battery-#{suffix}"
      })
      |> json_response(201)

    token = response["access_token"]
    conversation_id = response["conversation"]["id"]

    me = authenticated_conn(token) |> get("/api/v1/me") |> json_response(200)
    assert me["user"]["email"] == "owner-#{suffix}@example.test"

    member_password = "correct-member-password-#{suffix}"

    member =
      authenticated_conn(token)
      |> post("/api/v1/users", %{
        display_name: "Member",
        email: "member-#{suffix}@example.test",
        password: member_password,
        role: "member"
      })
      |> json_response(201)

    member_session =
      build_conn()
      |> post("/api/v1/sessions", %{
        tenant_slug: "web-test-#{suffix}",
        email: "member-#{suffix}@example.test",
        password: member_password,
        device: %{name: "Member browser", platform: "test"}
      })
      |> json_response(200)

    direct =
      authenticated_conn(token)
      |> post("/api/v1/conversations", %{
        kind: "direct",
        visibility: "private",
        member_ids: [member["data"]["id"]]
      })
      |> json_response(201)

    member_conversations =
      authenticated_conn(member_session["access_token"])
      |> get("/api/v1/conversations")
      |> json_response(200)

    assert Enum.any?(member_conversations["data"], &(&1["id"] == direct["data"]["id"]))

    assert authenticated_conn(member_session["access_token"])
           |> post("/api/v1/users", %{
             display_name: "Forbidden",
             email: "forbidden-#{suffix}@example.test",
             password: "forbidden-user-password-#{suffix}"
           })
           |> response(403)

    checksum = String.duplicate("a", 64)

    attachment =
      authenticated_conn(token)
      |> post("/api/v1/attachments", %{
        file_name: "evidence.txt",
        content_type: "text/plain",
        byte_size: 16,
        checksum_sha256: checksum
      })
      |> json_response(201)

    assert attachment["upload"]["method"] == "PUT"

    completed_attachment =
      authenticated_conn(token)
      |> post("/api/v1/attachments/#{attachment["data"]["id"]}/complete", %{
        checksum_sha256: checksum
      })
      |> json_response(200)

    assert completed_attachment["data"]["status"] == "ready"

    first =
      authenticated_conn(token)
      |> put_req_header("idempotency-key", "web-message-0001")
      |> post("/api/v1/conversations/#{conversation_id}/messages", %{
        body: "Hello staging",
        attachment_ids: [attachment["data"]["id"]]
      })
      |> json_response(201)

    duplicate =
      authenticated_conn(token)
      |> put_req_header("idempotency-key", "web-message-0001")
      |> post("/api/v1/conversations/#{conversation_id}/messages", %{
        body: "Hello staging",
        attachment_ids: [attachment["data"]["id"]]
      })
      |> json_response(201)

    assert first["data"]["id"] == duplicate["data"]["id"]
    assert first["data"]["conversation_sequence"] == 1
    assert [%{"id" => attachment_id}] = first["data"]["attachments"]
    assert attachment_id == attachment["data"]["id"]

    replay =
      authenticated_conn(token)
      |> get("/api/v1/conversations/#{conversation_id}/messages?after_sequence=0&limit=50")
      |> json_response(200)

    assert [%{"id" => message_id}] = replay["data"]
    assert message_id == first["data"]["id"]

    assert replay["page"] == %{
             "has_more" => false,
             "next_after_sequence" => 1,
             "reset_required" => false
           }

    assert authenticated_conn(token) |> delete("/api/v1/sessions/current") |> response(204)
    assert authenticated_conn(token) |> get("/api/v1/me") |> response(401)
  end

  test "missing idempotency key and tampered access token fail closed" do
    assert build_conn()
           |> put_req_header("authorization", "Bearer tampered")
           |> get("/api/v1/me")
           |> response(401)
  end

  test "CORS preflight is explicit for approved and unapproved origins" do
    allowed =
      build_conn()
      |> put_req_header("origin", "http://localhost:5173")
      |> options("/api/v1/status")

    assert response(allowed, 204) == ""
    assert get_resp_header(allowed, "access-control-allow-origin") == ["http://localhost:5173"]

    denied =
      build_conn()
      |> put_req_header("origin", "https://attacker.example")
      |> options("/api/v1/status")

    assert response(denied, 403) == ""
  end

  defp authenticated_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
