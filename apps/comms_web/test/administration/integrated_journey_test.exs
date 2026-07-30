defmodule CommsWeb.Administration.IntegratedJourneyTest do
  use CommsWeb.ConnCase, async: false

  @moduletag :integration
  @moduletag :administration

  test "tenant admin and member self-service journeys enforce role and version boundaries" do
    suffix = System.unique_integer([:positive, :monotonic])
    owner_email = "admin-owner-#{suffix}@example.test"
    owner_password = "correct-horse-admin-owner-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Admin Test #{suffix}",
        tenant_slug: "admin-test-#{suffix}",
        display_name: "Admin Owner",
        email: owner_email,
        password: owner_password
      })
      |> json_response(201)

    owner_token = bootstrap["access_token"]
    owner_id = bootstrap["user"]["id"]

    assert authenticated_conn(owner_token)
           |> patch("/api/v1/admin/tenant", %{version: 1, name: "Cold update"})
           |> response(428)

    assert authenticated_conn(owner_token)
           |> post("/api/v1/admin/invitations", %{
             email: "cold-invite-#{suffix}@example.test",
             role: "member"
           })
           |> response(428)

    step_up =
      authenticated_conn(owner_token)
      |> post("/api/v1/me/step-up", %{current_password: owner_password})
      |> json_response(200)

    assert is_binary(step_up["data"]["step_up_at"])

    settings =
      authenticated_conn(owner_token)
      |> patch("/api/v1/admin/tenant", %{
        version: 1,
        name: "Governed Admin Test #{suffix}",
        allow_public_channels: false,
        default_retention_days: 365
      })
      |> json_response(200)

    assert settings["data"]["settings"]["version"] == 2
    assert settings["data"]["settings"]["allow_public_channels"] == false

    assert authenticated_conn(owner_token)
           |> patch("/api/v1/admin/tenant", %{version: 2, max_attachment_bytes: 0})
           |> response(422)

    invitation =
      authenticated_conn(owner_token)
      |> put_req_header("idempotency-key", "invite-web-#{suffix}")
      |> post("/api/v1/admin/invitations", %{
        email: "invited-web-#{suffix}@example.test",
        role: "member"
      })
      |> json_response(201)

    assert invitation["replayed"] == false
    assert is_binary(invitation["invitation_token"])

    accepted =
      build_conn()
      |> post("/api/v1/invitations/accept", %{
        token: invitation["invitation_token"],
        display_name: "Invited Member",
        password: "correct-horse-invited-web-#{suffix}"
      })
      |> json_response(201)

    assert accepted
           |> Map.fetch!("data")
           |> Map.keys()
           |> Enum.sort() ==
             ~w(account_type display_name email id role status tenant_id version)

    member_id = accepted["data"]["id"]

    member_session =
      build_conn()
      |> post("/api/v1/sessions", %{
        tenant_slug: "admin-test-#{suffix}",
        email: "invited-web-#{suffix}@example.test",
        password: "correct-horse-invited-web-#{suffix}",
        device: %{name: "Invited browser", platform: "test"}
      })
      |> json_response(200)

    member_token = member_session["access_token"]

    admin_directory =
      authenticated_conn(owner_token)
      |> get("/api/v1/admin/users")
      |> json_response(200)

    assert Enum.all?(admin_directory["data"], &Map.has_key?(&1, "platform_role"))

    member_directory =
      authenticated_conn(owner_token)
      |> get("/api/v1/users")
      |> json_response(200)

    assert Enum.all?(member_directory["data"], &(not Map.has_key?(&1, "platform_role")))

    directory_conversation =
      authenticated_conn(owner_token)
      |> post("/api/v1/conversations", %{
        kind: "channel",
        title: "Directory presenter boundary",
        visibility: "private"
      })
      |> json_response(201)

    conversation_members =
      authenticated_conn(owner_token)
      |> get("/api/v1/conversations/#{directory_conversation["data"]["id"]}/members")
      |> json_response(200)

    assert Enum.all?(
             conversation_members["data"],
             &(not Map.has_key?(&1["user"], "platform_role"))
           )

    profile =
      authenticated_conn(member_token)
      |> patch("/api/v1/me/profile", %{display_name: "Updated Invited Member"})
      |> json_response(200)

    assert profile["data"]["display_name"] == "Updated Invited Member"

    same_email_profile =
      authenticated_conn(member_token)
      |> patch("/api/v1/me/profile", %{
        display_name: "Same Email Invited Member",
        email: "  INVITED-WEB-#{suffix}@EXAMPLE.TEST  "
      })
      |> json_response(200)

    assert same_email_profile["data"]["display_name"] == "Same Email Invited Member"
    assert same_email_profile["data"]["email"] == "invited-web-#{suffix}@example.test"

    changed_email_error =
      authenticated_conn(member_token)
      |> patch("/api/v1/me/profile", %{
        display_name: "Rejected Email Invited Member",
        email: "replacement-#{suffix}@example.test"
      })
      |> json_response(409)

    assert changed_email_error["error"]["code"] == "email_change_requires_verification"

    unchanged_profile =
      authenticated_conn(member_token)
      |> get("/api/v1/me")
      |> json_response(200)

    assert unchanged_profile["user"]["display_name"] == "Same Email Invited Member"
    assert unchanged_profile["user"]["email"] == "invited-web-#{suffix}@example.test"

    existing_identity_invitation_error =
      authenticated_conn(owner_token)
      |> post("/api/v1/admin/invitations", %{
        email: "invited-web-#{suffix}@example.test",
        role: "member"
      })
      |> json_response(409)

    assert existing_identity_invitation_error["error"]["code"] ==
             "invitation_identity_conflict"

    assert authenticated_conn(member_token)
           |> patch("/api/v1/me/profile", %{display_name: ""})
           |> response(422)

    assert [_] =
             authenticated_conn(member_token)
             |> get("/api/v1/me/devices")
             |> json_response(200)
             |> Map.fetch!("data")

    assert [_] =
             authenticated_conn(member_token)
             |> get("/api/v1/me/sessions")
             |> json_response(200)
             |> Map.fetch!("data")

    assert authenticated_conn(member_token)
           |> get("/api/v1/admin/tenant")
           |> response(403)

    assert authenticated_conn(member_token)
           |> get("/api/v1/admin/users")
           |> response(403)

    report =
      authenticated_conn(member_token)
      |> put_req_header("idempotency-key", "report-web-#{suffix}")
      |> post("/api/v1/moderation/cases", %{
        subject_user_id: owner_id,
        category: "conduct",
        summary: "Request moderator review"
      })
      |> json_response(201)

    assert report["data"]["status"] == "open"
    assert authenticated_conn(member_token) |> get("/api/v1/moderation/cases") |> response(403)

    promoted =
      authenticated_conn(owner_token)
      |> patch("/api/v1/admin/users/#{member_id}", %{
        version: 1,
        role: "moderator",
        reason: "assign moderation responsibility"
      })
      |> json_response(200)

    assert promoted["data"]["role"] == "moderator"

    invalid_user_error =
      authenticated_conn(owner_token)
      |> patch("/api/v1/admin/users/not-a-uuid", %{
        version: 1,
        role: "member",
        reason: "invalid user identifiers must not reach persistence"
      })
      |> json_response(404)

    assert invalid_user_error["error"]["code"] == "not_found"

    assert [_] =
             authenticated_conn(member_token)
             |> get("/api/v1/moderation/cases")
             |> json_response(200)
             |> Map.fetch!("data")

    assert authenticated_conn(member_token)
           |> post("/api/v1/moderation/cases/#{report["data"]["id"]}/actions", %{
             action_type: "start_review",
             note: "begin review",
             version: report["data"]["version"]
           })
           |> response(428)

    authenticated_conn(member_token)
    |> post("/api/v1/me/step-up", %{
      current_password: "correct-horse-invited-web-#{suffix}"
    })
    |> json_response(200)

    reviewed =
      authenticated_conn(member_token)
      |> post("/api/v1/moderation/cases/#{report["data"]["id"]}/actions", %{
        action_type: "start_review",
        note: "begin review",
        version: report["data"]["version"]
      })
      |> json_response(200)

    assert reviewed["data"]["status"] == "in_review"

    audit =
      authenticated_conn(owner_token)
      |> get("/api/v1/admin/audit-events?action=tenant.settings_update")
      |> json_response(200)

    assert [%{"resource_id" => resource_id}] = audit["data"]
    assert resource_id == bootstrap["tenant"]["id"]

    policy =
      authenticated_conn(owner_token)
      |> put_req_header("idempotency-key", "policy-web-#{suffix}")
      |> post("/api/v1/admin/retention-policies", %{
        name: "Default",
        scope_type: "tenant",
        retention_days: 365
      })
      |> json_response(201)

    assert policy["data"]["retention_days"] == 365
  end

  defp authenticated_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
