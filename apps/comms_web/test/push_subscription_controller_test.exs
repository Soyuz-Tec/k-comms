defmodule CommsWeb.PushSubscriptionControllerTest do
  use CommsWeb.ConnCase, async: false

  @p256dh "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
  @auth "AAECAwQFBgcICQoLDA0ODw"

  test "authenticated browsers configure, register, list, and revoke only their device subscription" do
    suffix = System.unique_integer([:positive, :monotonic])
    email = "push-web-#{suffix}@example.test"
    password = "correct-horse-push-web-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Push Web #{suffix}",
        tenant_slug: "push-web-#{suffix}",
        display_name: "Push Owner",
        email: email,
        password: password
      })
      |> json_response(201)

    first_token = bootstrap["access_token"]

    config =
      authenticated_conn(first_token)
      |> get("/api/v1/me/push-subscriptions/config")
      |> json_response(200)

    assert config["data"]["available"] == true
    assert config["data"]["vapid_public_key"] == @p256dh

    assert authenticated_conn(first_token)
           |> get("/api/v1/me/push-subscriptions")
           |> json_response(200) == %{"data" => []}

    endpoint = "https://push.example.test/send/controller-secret?token=private"
    body = subscription_body(endpoint)

    created =
      authenticated_conn(first_token)
      |> post("/api/v1/me/push-subscriptions", body)
      |> json_response(201)

    assert created["replayed"] == false
    assert created["data"]["endpoint_hint"] == "push.example.test"
    assert created["data"]["status"] == "active"
    refute Jason.encode!(created) =~ "controller-secret"
    refute Jason.encode!(created) =~ "token=private"
    refute Jason.encode!(created) =~ @p256dh
    refute Jason.encode!(created) =~ @auth

    replayed =
      authenticated_conn(first_token)
      |> post("/api/v1/me/push-subscriptions", body)
      |> json_response(200)

    assert replayed["replayed"] == true
    assert replayed["data"]["id"] == created["data"]["id"]

    second_session =
      build_conn()
      |> post("/api/v1/sessions", %{
        tenant_slug: "push-web-#{suffix}",
        email: email,
        password: password,
        device: %{name: "Second browser", platform: "test"}
      })
      |> json_response(200)

    second_token = second_session["access_token"]

    assert authenticated_conn(second_token)
           |> get("/api/v1/me/push-subscriptions")
           |> json_response(200) == %{"data" => []}

    assert authenticated_conn(second_token)
           |> delete("/api/v1/me/push-subscriptions/#{created["data"]["id"]}")
           |> response(404)

    revoked =
      authenticated_conn(first_token)
      |> delete("/api/v1/me/push-subscriptions/#{created["data"]["id"]}")
      |> json_response(200)

    assert revoked["data"]["status"] == "revoked"
  end

  test "deny-all notification delivery disables browser push configuration and registration" do
    previous_status = Application.get_env(:comms_core, :push_delivery_status)
    previous_adapter = Application.get_env(:comms_integrations, :notification_adapter)

    on_exit(fn ->
      restore(:comms_core, :push_delivery_status, previous_status)
      restore(:comms_integrations, :notification_adapter, previous_adapter)
    end)

    Application.put_env(:comms_core, :push_delivery_status, :unavailable)

    Application.put_env(
      :comms_integrations,
      :notification_adapter,
      CommsIntegrations.Notifications.DenyAll
    )

    suffix = System.unique_integer([:positive, :monotonic])

    session =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Push Disabled #{suffix}",
        tenant_slug: "push-disabled-#{suffix}",
        display_name: "Push Disabled Owner",
        email: "push-disabled-#{suffix}@example.test",
        password: "correct-horse-push-disabled-#{suffix}"
      })
      |> json_response(201)

    token = session["access_token"]

    assert authenticated_conn(token)
           |> get("/api/v1/me/push-subscriptions/config")
           |> json_response(200) == %{
             "data" => %{"available" => false, "vapid_public_key" => nil}
           }

    response =
      authenticated_conn(token)
      |> post(
        "/api/v1/me/push-subscriptions",
        subscription_body("https://push.example.test/send/disabled")
      )
      |> json_response(503)

    assert response["error"]["code"] == "provider_unavailable"
  end

  test "push endpoints reject unauthenticated and invalid capability input" do
    assert build_conn() |> get("/api/v1/me/push-subscriptions/config") |> response(401)

    suffix = System.unique_integer([:positive, :monotonic])

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Push Invalid #{suffix}",
        tenant_slug: "push-invalid-#{suffix}",
        display_name: "Push Owner",
        email: "push-invalid-#{suffix}@example.test",
        password: "correct-horse-push-invalid-#{suffix}"
      })
      |> json_response(201)

    assert authenticated_conn(bootstrap["access_token"])
           |> post(
             "/api/v1/me/push-subscriptions",
             subscription_body("http://push.example.test/not-secure")
           )
           |> json_response(422)
           |> get_in(["error", "code"]) == "invalid_push_endpoint"
  end

  test "a device cannot register more than the active subscription capacity" do
    suffix = System.unique_integer([:positive, :monotonic])

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Push Capacity #{suffix}",
        tenant_slug: "push-capacity-#{suffix}",
        display_name: "Push Owner",
        email: "push-capacity-#{suffix}@example.test",
        password: "correct-horse-push-capacity-#{suffix}"
      })
      |> json_response(201)

    for index <- 1..5 do
      assert authenticated_conn(bootstrap["access_token"])
             |> post(
               "/api/v1/me/push-subscriptions",
               subscription_body("https://push.example.test/send/capacity-#{index}")
             )
             |> response(201)
    end

    conflict =
      authenticated_conn(bootstrap["access_token"])
      |> post(
        "/api/v1/me/push-subscriptions",
        subscription_body("https://push.example.test/send/capacity-6")
      )
      |> json_response(409)

    assert conflict["error"]["code"] == "push_subscription_limit_reached"
  end

  defp subscription_body(endpoint) do
    %{
      endpoint: endpoint,
      expiration_time: nil,
      keys: %{p256dh: @p256dh, auth: @auth}
    }
  end

  defp authenticated_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp restore(application, key, nil), do: Application.delete_env(application, key)
  defp restore(application, key, value), do: Application.put_env(application, key, value)
end
