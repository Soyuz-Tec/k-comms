defmodule CommsWeb.IntegrationsSafetyOps.NotificationRetryTest do
  use CommsWeb.IntegrationSafetyOpsCase

  @moduletag :integration
  @moduletag :integrations
  @moduletag :notification

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
end
