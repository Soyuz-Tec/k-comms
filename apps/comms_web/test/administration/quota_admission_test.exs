defmodule CommsWeb.Administration.QuotaAdmissionTest do
  use CommsWeb.ConnCase, async: false

  @moduletag :integration
  @moduletag :administration

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
