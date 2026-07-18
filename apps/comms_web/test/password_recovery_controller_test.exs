defmodule CommsWeb.PasswordRecoveryControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Notifications.Intent
  alias CommsCore.{PasswordRecovery, Repo}

  test "request responses do not enumerate accounts and reset never logs in automatically" do
    suffix = System.unique_integer([:positive, :monotonic])
    tenant_slug = "recovery-web-#{suffix}"
    email = "recovery-web-#{suffix}@example.test"
    old_password = "correct-horse-recovery-web-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Recovery Web #{suffix}",
        tenant_slug: tenant_slug,
        display_name: "Recovery Owner",
        email: email,
        password: old_password
      })
      |> json_response(201)

    known =
      build_conn()
      |> post("/api/v1/password-recovery/requests", %{
        tenant_slug: tenant_slug,
        email: email
      })
      |> json_response(202)

    unknown =
      build_conn()
      |> post("/api/v1/password-recovery/requests", %{
        tenant_slug: "unknown-#{suffix}",
        email: "unknown-#{suffix}@example.test"
      })
      |> json_response(202)

    assert known == %{"data" => %{"status" => "accepted"}}
    assert unknown == known

    intent = Repo.get_by!(Intent, event_type: PasswordRecovery.event_type())

    {:ok, delivery} =
      PasswordRecovery.materialize_notification(%{
        tenant_id: intent.tenant_id,
        user_id: intent.user_id,
        recovery_request_id: intent.payload["recovery_request_id"]
      })

    token = token_from_url(delivery.payload["action_url"])

    assert build_conn()
           |> post("/api/v1/password-recovery/resets", %{
             token: "invalid-token",
             new_password: "correct-horse-invalid-token"
           })
           |> json_response(400)
           |> get_in(["error", "code"]) == "invalid_recovery_token"

    assert build_conn()
           |> post("/api/v1/password-recovery/resets", %{
             token: token,
             new_password: "short"
           })
           |> json_response(422)
           |> get_in(["error", "code"]) == "weak_password"

    reset_conn =
      build_conn()
      |> post("/api/v1/password-recovery/resets", %{
        token: token,
        new_password: "correct-horse-recovered-web-password"
      })

    assert response(reset_conn, 204) == ""
    refute get_resp_header(reset_conn, "authorization") != []

    assert build_conn()
           |> put_req_header("authorization", "Bearer #{bootstrap["access_token"]}")
           |> get("/api/v1/me")
           |> response(401)

    assert build_conn()
           |> post("/api/v1/password-recovery/resets", %{
             token: token,
             new_password: "another-correct-horse-password"
           })
           |> json_response(400)
           |> get_in(["error", "code"]) == "invalid_recovery_token"

    assert build_conn()
           |> post("/api/v1/sessions", %{
             tenant_slug: tenant_slug,
             email: email,
             password: old_password
           })
           |> response(401)

    recovered_login =
      build_conn()
      |> post("/api/v1/sessions", %{
        tenant_slug: tenant_slug,
        email: email,
        password: "correct-horse-recovered-web-password"
      })
      |> json_response(200)

    assert is_binary(recovered_login["access_token"])
  end

  defp token_from_url(url) do
    url |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")
  end
end
