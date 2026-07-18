defmodule CommsWeb.IntegrationsSafetyOpsControllerTest do
  use CommsWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias CommsCore.Accounts.PlatformRoleGrant
  alias CommsCore.Repo

  test "owners manage notification settings, webhooks, attachment safety, and ops without secret leakage" do
    previous_webhook_http = Application.get_env(:comms_integrations, :webhook_http)

    Application.put_env(:comms_integrations, :webhook_http,
      allowed_hosts: ["hooks.example.test"],
      allowed_ports: [443],
      timeout_ms: 100
    )

    on_exit(fn ->
      if previous_webhook_http do
        Application.put_env(:comms_integrations, :webhook_http, previous_webhook_http)
      else
        Application.delete_env(:comms_integrations, :webhook_http)
      end
    end)

    owner = bootstrap_owner()
    token = owner.token

    preferences =
      authenticated_conn(token)
      |> get("/api/v1/notification-preferences")
      |> json_response(200)

    assert preferences["data"]["email_enabled"]

    updated_preferences =
      authenticated_conn(token)
      |> put("/api/v1/notification-preferences", %{
        email_enabled: false,
        push_enabled: false,
        in_app_enabled: true,
        muted_event_types: ["message.edited.v1"]
      })
      |> json_response(200)

    refute updated_preferences["data"]["email_enabled"]

    assert authenticated_conn(token)
           |> post("/api/v1/admin/webhooks", %{
             name: "Cold sink",
             url: "https://hooks.example.test/cold",
             event_types: ["message.created.v1"]
           })
           |> response(428)

    authenticated_conn(token)
    |> post("/api/v1/me/step-up", %{current_password: owner.password})
    |> json_response(200)

    created =
      authenticated_conn(token)
      |> post("/api/v1/admin/webhooks", %{
        name: "Audit sink",
        url: "https://hooks.example.test/events",
        event_types: ["message.created.v1"]
      })
      |> json_response(201)

    assert is_binary(created["secret"])
    endpoint_id = created["data"]["id"]

    listed =
      authenticated_conn(token)
      |> get("/api/v1/admin/webhooks")
      |> json_response(200)

    assert [%{"id" => ^endpoint_id} = listed_endpoint] = listed["data"]
    refute Map.has_key?(listed_endpoint, "secret")

    rotated =
      authenticated_conn(token)
      |> post("/api/v1/admin/webhooks/#{endpoint_id}/rotate-secret")
      |> json_response(200)

    assert rotated["data"]["secret_version"] == 2
    refute rotated["secret"] == created["secret"]

    attachment =
      authenticated_conn(token)
      |> post("/api/v1/attachments", %{
        file_name: "pending.txt",
        content_type: "text/plain",
        byte_size: 12,
        checksum_sha256: String.duplicate("a", 64)
      })
      |> json_response(201)

    attachment_id = attachment["data"]["id"]

    completed =
      authenticated_conn(token)
      |> post("/api/v1/attachments/#{attachment_id}/complete", %{})
      |> json_response(200)

    assert completed["data"]["status"] == "uploaded"
    assert completed["data"]["scan_status"] == "pending"

    pending =
      authenticated_conn(token)
      |> get("/api/v1/attachments/#{attachment_id}")
      |> json_response(200)

    refute Map.has_key?(pending, "download")

    safety =
      authenticated_conn(token)
      |> get("/api/v1/admin/attachment-safety?scan_status=pending")
      |> json_response(200)

    assert Enum.any?(safety["data"], &(&1["id"] == attachment_id))

    ops = authenticated_conn(token) |> get("/api/v1/ops") |> json_response(200)
    refute Map.has_key?(ops["data"], "database")
    assert is_map(ops["data"]["providers"])
    refute Jason.encode!(ops) =~ "k-comms-staging"

    assert authenticated_conn(token)
           |> get("/api/v1/platform/ops")
           |> json_response(403)
           |> get_in(["error", "code"]) == "forbidden"

    encoded = Jason.encode!(%{listed: listed, ops: ops})
    refute encoded =~ created["secret"]
    refute encoded =~ rotated["secret"]
  end

  test "webhook endpoint creation rejects destinations outside the configured allowlist" do
    owner = bootstrap_owner()
    token = owner.token

    authenticated_conn(token)
    |> post("/api/v1/me/step-up", %{current_password: owner.password})
    |> json_response(200)

    assert authenticated_conn(token)
           |> post("/api/v1/admin/webhooks", %{
             name: "Blocked",
             url: "https://127.0.0.1/events",
             event_types: ["message.created.v1"]
           })
           |> json_response(422)
           |> get_in(["error", "code"]) == "invalid_webhook_destination"
  end

  test "attachment safety retries require recent step-up" do
    owner = bootstrap_owner()

    attachment =
      authenticated_conn(owner.token)
      |> post("/api/v1/attachments", %{
        file_name: "retry.txt",
        content_type: "text/plain",
        byte_size: 12,
        checksum_sha256: String.duplicate("b", 64)
      })
      |> json_response(201)

    attachment_id = attachment["data"]["id"]

    authenticated_conn(owner.token)
    |> post("/api/v1/attachments/#{attachment_id}/complete", %{})
    |> json_response(200)

    assert authenticated_conn(owner.token)
           |> post("/api/v1/admin/attachment-safety/#{attachment_id}/retry")
           |> response(428)

    authenticated_conn(owner.token)
    |> post("/api/v1/me/step-up", %{current_password: owner.password})
    |> json_response(200)

    retried =
      authenticated_conn(owner.token)
      |> post("/api/v1/admin/attachment-safety/#{attachment_id}/retry")
      |> json_response(202)

    assert retried["data"]["id"] == attachment_id
  end

  test "notification delivery retries require recent step-up" do
    owner = bootstrap_owner()
    assert {:ok, authenticated} = CommsWeb.Token.verify(owner.token)

    assert {:ok, intent} =
             CommsCore.Notifications.create_intent(%{
               tenant_id: authenticated.user.tenant_id,
               user_id: authenticated.user.id,
               event_type: "message.created.v1",
               channel: :email,
               destination: authenticated.user.email,
               payload: %{"title" => "Retry", "body" => "Retry delivery"},
               idempotency_key: "notification-controller-retry"
             })

    assert {:ok, ops_intent} =
             CommsCore.Notifications.create_intent(%{
               tenant_id: authenticated.user.tenant_id,
               user_id: authenticated.user.id,
               event_type: "message.created.v1",
               channel: :email,
               destination: authenticated.user.email,
               payload: %{"title" => "Ops retry", "body" => "Retry delivery from operations"},
               idempotency_key: "notification-ops-retry"
             })

    assert authenticated_conn(owner.token)
           |> post("/api/v1/notification-intents/#{intent.id}/retry")
           |> response(428)

    assert authenticated_conn(owner.token)
           |> post("/api/v1/ops/retry", %{
             resource_type: "notification",
             id: ops_intent.id
           })
           |> response(428)

    authenticated_conn(owner.token)
    |> post("/api/v1/me/step-up", %{current_password: owner.password})
    |> json_response(200)

    retried =
      authenticated_conn(owner.token)
      |> post("/api/v1/notification-intents/#{intent.id}/retry")
      |> json_response(202)

    assert retried["data"]["id"] == intent.id
    assert retried["data"]["status"] == "pending"

    ops_retried =
      authenticated_conn(owner.token)
      |> post("/api/v1/ops/retry", %{
        resource_type: "notification",
        id: ops_intent.id
      })
      |> json_response(202)

    assert ops_retried["data"]["id"] == ops_intent.id
    assert ops_retried["data"]["status"] == "pending"
  end

  test "platform role is persisted, presented, and required for platform operations" do
    previous_secret = Application.get_env(:comms_core, :platform_role_management_secret)
    secret = String.duplicate("web-platform-management-secret-", 2)
    Application.put_env(:comms_core, :platform_role_management_secret, secret)

    on_exit(fn ->
      if previous_secret,
        do: Application.put_env(:comms_core, :platform_role_management_secret, previous_secret),
        else: Application.delete_env(:comms_core, :platform_role_management_secret)
    end)

    token = bootstrap_owner().token
    assert {:ok, authenticated} = CommsWeb.Token.verify(token)

    assert authenticated_conn(token)
           |> get("/api/v1/me")
           |> json_response(200)
           |> get_in(["user", "platform_role"]) == nil

    assert {:ok, _user} =
             CommsCore.Accounts.set_platform_role_from_console(
               authenticated.user.id,
               :platform_operator,
               %{
                 grant_token: secret,
                 actor: "web-operations-test",
                 reason: "verify platform operator HTTP identity",
                 ttl_seconds: 3600
               }
             )

    identity = authenticated_conn(token) |> get("/api/v1/me") |> json_response(200)
    assert get_in(identity, ["user", "platform_role"]) == "platform_operator"
    assert is_binary(get_in(identity, ["user", "platform_role_expires_at"]))

    sessions =
      authenticated_conn(token)
      |> get("/api/v1/me/sessions")
      |> json_response(200)

    assert [session] = sessions["data"]
    assert session["platform_role"] == "platform_operator"
    assert is_binary(session["platform_role_expires_at"])

    platform_ops =
      authenticated_conn(token) |> get("/api/v1/platform/ops") |> json_response(200)

    assert is_binary(platform_ops["data"]["release_revision"])
    assert platform_ops["data"]["providers"]["browser_push"]["status"] == "available"
    refute Map.has_key?(platform_ops["data"]["providers"]["browser_push"], "encryption")

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(grant in PlatformRoleGrant, where: grant.user_id == ^authenticated.user.id),
      set: [expires_at: expired_at, inserted_at: DateTime.add(expired_at, -3600, :second)]
    )

    expired_identity = authenticated_conn(token) |> get("/api/v1/me") |> json_response(200)
    assert get_in(expired_identity, ["user", "platform_role"]) == nil
    assert get_in(expired_identity, ["user", "platform_role_expires_at"]) == nil

    assert authenticated_conn(token)
           |> get("/api/v1/platform/ops")
           |> json_response(403)
           |> get_in(["error", "code"]) == "forbidden"

    assert {:ok, _user} =
             CommsCore.Accounts.set_platform_role_from_console(authenticated.user.id, nil, %{
               grant_token: secret,
               actor: "web-operations-test",
               reason: "verify immediate platform role revocation"
             })

    assert authenticated_conn(token)
           |> get("/api/v1/platform/ops")
           |> json_response(403)
           |> get_in(["error", "code"]) == "forbidden"

    assert {:ok, _user} =
             CommsCore.Accounts.set_platform_role_from_console(
               authenticated.user.id,
               :support_operator,
               %{
                 grant_token: secret,
                 actor: "web-operations-test",
                 reason: "verify content-blind support visibility",
                 ttl_seconds: 3600
               }
             )

    assert authenticated_conn(token) |> get("/api/v1/platform/ops") |> json_response(200)
  end

  defp bootstrap_owner do
    suffix = System.unique_integer([:positive, :monotonic])

    response =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Integration Test #{suffix}",
        tenant_slug: "integration-test-#{suffix}",
        display_name: "Owner",
        email: "owner-#{suffix}@example.test",
        password: "correct-horse-battery-#{suffix}"
      })
      |> json_response(201)

    %{token: response["access_token"], password: "correct-horse-battery-#{suffix}"}
  end

  defp authenticated_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
