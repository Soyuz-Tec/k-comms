defmodule CommsWeb.IntegrationsSafetyOps.WebhookPolicyTest do
  use CommsWeb.IntegrationSafetyOpsCase

  @moduletag :integration
  @moduletag :integrations

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
end
