defmodule CommsWeb.AdministrationControllerTest do
  use CommsWeb.ConnCase, async: false

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

  test "tenant quota usage and admission failures are exposed with stable API codes" do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-horse-quota-owner-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Quota API #{suffix}",
        tenant_slug: "quota-api-#{suffix}",
        display_name: "Quota Owner",
        email: "quota-owner-#{suffix}@example.test",
        password: password
      })
      |> json_response(201)

    token = bootstrap["access_token"]

    authenticated_conn(token)
    |> post("/api/v1/me/step-up", %{current_password: password})
    |> json_response(200)

    initial = authenticated_conn(token) |> get("/api/v1/admin/tenant") |> json_response(200)
    assert initial["data"]["usage"]["active_users"] == 1
    assert initial["data"]["usage"]["active_conversations"] == 1
    assert initial["data"]["settings"]["max_conversation_members"] == 250

    capacity =
      authenticated_conn(token)
      |> patch("/api/v1/admin/tenant", %{
        version: 1,
        max_active_users: 1,
        max_active_conversations: 1,
        max_conversation_members: 2
      })
      |> json_response(200)

    assert capacity["data"]["usage"]["at_capacity"]["active_users"]
    assert capacity["data"]["usage"]["at_capacity"]["active_conversations"]
    refute capacity["data"]["usage"]["over_limit"]["any"]

    blocked_invitation =
      authenticated_conn(token)
      |> post("/api/v1/admin/invitations", %{
        email: "blocked-user-#{suffix}@example.test",
        role: "member"
      })
      |> json_response(201)

    user_error =
      build_conn()
      |> post("/api/v1/invitations/accept", %{
        token: blocked_invitation["invitation_token"],
        display_name: "Blocked user",
        password: "correct-horse-blocked-user-#{suffix}"
      })
      |> json_response(409)

    assert user_error["error"]["code"] == "active_user_quota_exceeded"

    conversation_error =
      authenticated_conn(token)
      |> post("/api/v1/conversations", %{kind: "group", title: "Blocked conversation"})
      |> json_response(409)

    assert conversation_error["error"]["code"] == "active_conversation_quota_exceeded"

    authenticated_conn(token)
    |> patch("/api/v1/admin/tenant", %{version: 2, max_active_users: 3})
    |> json_response(200)

    member_ids =
      for index <- 1..2 do
        member_email = "quota-member-#{index}-#{suffix}@example.test"

        invitation =
          authenticated_conn(token)
          |> post("/api/v1/admin/invitations", %{
            email: member_email,
            role: "member"
          })
          |> json_response(201)

        build_conn()
        |> post("/api/v1/invitations/accept", %{
          token: invitation["invitation_token"],
          display_name: "Quota member #{index}",
          email: "quota-member-#{index}-#{suffix}@example.test",
          password: "correct-horse-quota-member-#{index}-#{suffix}"
        })
        |> json_response(201)
        |> get_in(["data", "id"])
      end

    [admitted_id, blocked_id] = member_ids
    conversation_id = bootstrap["conversation"]["id"]

    authenticated_conn(token)
    |> post("/api/v1/conversations/#{conversation_id}/members", %{
      user_id: admitted_id,
      role: "member"
    })
    |> json_response(201)

    membership_error =
      authenticated_conn(token)
      |> post("/api/v1/conversations/#{conversation_id}/members", %{
        user_id: blocked_id,
        role: "member"
      })
      |> json_response(409)

    assert membership_error["error"]["code"] == "conversation_member_quota_exceeded"
  end

  defp authenticated_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
