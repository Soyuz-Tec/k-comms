defmodule CommsWeb.ServiceAccountControllerTest do
  use CommsWeb.ConnCase, async: false

  test "admin lifecycle issues one-time credentials and service APIs stay on a separate boundary" do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-horse-service-owner-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Service Tenant #{suffix}",
        tenant_slug: "service-tenant-#{suffix}",
        display_name: "Service Owner",
        email: "service-owner-#{suffix}@example.test",
        password: password
      })
      |> json_response(201)

    human_token = bootstrap["access_token"]
    conversation_id = bootstrap["conversation"]["id"]

    assert authenticated_conn(human_token)
           |> get("/api/v1/admin/service-accounts")
           |> response(428)

    authenticated_conn(human_token)
    |> post("/api/v1/me/step-up", %{current_password: password})
    |> json_response(200)

    created =
      authenticated_conn(human_token)
      |> post("/api/v1/admin/service-accounts", %{
        name: "Release Bot",
        scopes: [
          "conversations:read",
          "messages:read",
          "messages:write",
          "search:read"
        ],
        reason: "Automate release notices"
      })
      |> json_response(201)

    credential = created["credential"]
    service_id = created["data"]["id"]
    bot_user_id = created["data"]["user_id"]
    assert credential =~ ~r/^kcsa_/
    refute Map.has_key?(created["data"], "secret_hash")

    listed =
      authenticated_conn(human_token)
      |> get("/api/v1/admin/service-accounts")
      |> json_response(200)

    assert [%{"id" => ^service_id} = listed_account] = listed["data"]
    refute Map.has_key?(listed_account, "credential")
    refute Map.has_key?(listed_account, "secret_hash")

    directory =
      authenticated_conn(human_token)
      |> get("/api/v1/users")
      |> json_response(200)

    bot = Enum.find(directory["data"], &(&1["id"] == bot_user_id))
    assert bot["account_type"] == "service"
    assert bot["email"] == nil

    assert build_conn()
           |> post("/api/v1/sessions", %{
             tenant_slug: "service-tenant-#{suffix}",
             email: "#{service_id}@service.invalid",
             password: "not-a-human-password"
           })
           |> response(401)

    assert authenticated_conn(human_token)
           |> get("/api/v1/service/conversations")
           |> response(401)

    assert service_conn(credential)
           |> get("/api/v1/admin/service-accounts")
           |> response(401)

    assert service_conn(credential)
           |> post("/api/v1/socket-tickets")
           |> response(401)

    assert service_conn(credential)
           |> get("/api/v1/service/conversations")
           |> json_response(200) == %{"data" => []}

    assert service_conn(credential)
           |> get("/api/v1/service/conversations/#{conversation_id}/messages")
           |> response(403)

    assert service_conn(credential)
           |> put_req_header("idempotency-key", "service-message-0001")
           |> post("/api/v1/service/conversations/#{conversation_id}/messages", %{body: "blocked"})
           |> response(403)

    assert service_conn(credential)
           |> get("/api/v1/service/search?q=blocked")
           |> json_response(200) == %{"data" => []}

    authenticated_conn(human_token)
    |> post("/api/v1/conversations/#{conversation_id}/members", %{
      user_id: bot_user_id,
      role: "member"
    })
    |> json_response(201)

    assert %{"data" => [%{"id" => ^conversation_id}]} =
             service_conn(credential)
             |> get("/api/v1/service/conversations")
             |> json_response(200)

    first =
      service_conn(credential)
      |> put_req_header("idempotency-key", "service-message-0001")
      |> post("/api/v1/service/conversations/#{conversation_id}/messages", %{
        body: "Release 42 is ready"
      })
      |> json_response(201)

    assert first["replayed"] == false
    assert first["data"]["sender_user_id"] == bot_user_id

    replay =
      service_conn(credential)
      |> put_req_header("idempotency-key", "service-message-0001")
      |> post("/api/v1/service/conversations/#{conversation_id}/messages", %{
        body: "Release 42 is ready"
      })
      |> json_response(200)

    assert replay["replayed"] == true
    assert replay["data"]["id"] == first["data"]["id"]

    history =
      service_conn(credential)
      |> get("/api/v1/service/conversations/#{conversation_id}/messages")
      |> json_response(200)

    assert Enum.any?(history["data"], &(&1["id"] == first["data"]["id"]))

    search =
      service_conn(credential)
      |> get("/api/v1/service/search?q=Release+42")
      |> json_response(200)

    assert Enum.any?(search["data"], &(&1["id"] == first["data"]["id"]))

    rotated =
      authenticated_conn(human_token)
      |> post("/api/v1/admin/service-accounts/#{service_id}/rotate", %{
        version: created["data"]["version"],
        reason: "Scheduled rotation"
      })
      |> json_response(200)

    assert service_conn(credential)
           |> get("/api/v1/service/conversations")
           |> response(401)

    revoked =
      authenticated_conn(human_token)
      |> post("/api/v1/admin/service-accounts/#{service_id}/revoke", %{
        version: rotated["data"]["version"],
        reason: "Automation retired"
      })
      |> json_response(200)

    assert revoked["data"]["status"] == "revoked"

    assert service_conn(rotated["credential"])
           |> get("/api/v1/service/conversations")
           |> response(401)
  end

  test "wrong-scope service credentials fail every capability closed" do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-horse-scope-owner-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Scope Tenant #{suffix}",
        tenant_slug: "scope-tenant-#{suffix}",
        display_name: "Scope Owner",
        email: "scope-owner-#{suffix}@example.test",
        password: password
      })
      |> json_response(201)

    token = bootstrap["access_token"]
    conversation_id = bootstrap["conversation"]["id"]

    authenticated_conn(token)
    |> post("/api/v1/me/step-up", %{current_password: password})
    |> json_response(200)

    created =
      authenticated_conn(token)
      |> post("/api/v1/admin/service-accounts", %{
        name: "Directory-only Bot",
        scopes: ["conversations:read"],
        reason: "Only enumerate joined conversations"
      })
      |> json_response(201)

    authenticated_conn(token)
    |> post("/api/v1/conversations/#{conversation_id}/members", %{
      user_id: created["data"]["user_id"],
      role: "member"
    })
    |> json_response(201)

    credential = created["credential"]
    assert service_conn(credential) |> get("/api/v1/service/conversations") |> response(200)

    assert service_conn(credential)
           |> get("/api/v1/service/conversations/#{conversation_id}/messages")
           |> response(403)

    assert service_conn(credential)
           |> put_req_header("idempotency-key", "wrong-scope-0001")
           |> post("/api/v1/service/conversations/#{conversation_id}/messages", %{body: "blocked"})
           |> response(403)

    assert service_conn(credential) |> get("/api/v1/service/search?q=blocked") |> response(403)

    list_forbidden =
      authenticated_conn(token)
      |> post("/api/v1/admin/service-accounts", %{
        name: "History-only Bot",
        scopes: ["messages:read"],
        reason: "Must not enumerate conversations"
      })
      |> json_response(201)

    assert service_conn(list_forbidden["credential"])
           |> get("/api/v1/service/conversations")
           |> response(403)
  end

  defp authenticated_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp service_conn(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
