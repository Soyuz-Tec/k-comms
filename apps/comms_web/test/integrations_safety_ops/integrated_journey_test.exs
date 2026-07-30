defmodule CommsWeb.IntegrationsSafetyOps.IntegratedJourneyTest do
  use CommsWeb.IntegrationSafetyOpsCase

  @moduletag :integration
  @moduletag :integrations

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
end
