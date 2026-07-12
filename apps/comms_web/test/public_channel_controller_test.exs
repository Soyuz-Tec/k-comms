defmodule CommsWeb.PublicChannelControllerTest do
  use CommsWeb.ConnCase, async: false

  test "authenticated users can discover, join, and leave tenant-visible channels idempotently" do
    suffix = System.unique_integer([:positive, :monotonic])
    tenant_slug = "channel-web-#{suffix}"
    owner_password = "correct-owner-password-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Channel Web #{suffix}",
        tenant_slug: tenant_slug,
        display_name: "Owner",
        email: "channel-owner-#{suffix}@example.test",
        password: owner_password
      })
      |> json_response(201)

    owner_token = bootstrap["access_token"]

    channel =
      authenticated_conn(owner_token)
      |> post("/api/v1/conversations", %{
        kind: "channel",
        title: "Town Square #{suffix}",
        visibility: "tenant"
      })
      |> json_response(201)

    member_password = "correct-member-password-#{suffix}"
    member_email = "channel-web-member-#{suffix}@example.test"

    authenticated_conn(owner_token)
    |> post("/api/v1/me/step-up", %{current_password: owner_password})
    |> json_response(200)

    invitation =
      authenticated_conn(owner_token)
      |> post("/api/v1/admin/invitations", %{email: member_email, role: "member"})
      |> json_response(201)

    member =
      build_conn()
      |> post("/api/v1/invitations/accept", %{
        token: invitation["invitation_token"],
        display_name: "Channel Member",
        password: member_password
      })
      |> json_response(201)

    session =
      build_conn()
      |> post("/api/v1/sessions", %{
        tenant_slug: tenant_slug,
        email: member_email,
        password: member_password,
        device: %{name: "Channel browser", platform: "test"}
      })
      |> json_response(200)

    member_token = session["access_token"]

    discovery =
      authenticated_conn(member_token)
      |> get("/api/v1/channels/discover?q=Town&limit=10")
      |> json_response(200)

    assert discovery["page"] == %{
             "has_more" => false,
             "limit" => 10,
             "next_cursor" => nil
           }

    assert [discoverable] = discovery["data"]
    assert discoverable["id"] == channel["data"]["id"]
    assert discoverable["visibility"] == "tenant"
    assert discoverable["archived_at"] == nil
    refute discoverable["joined"]
    assert discoverable["membership"] == nil
    assert discoverable["member_count"] == 1

    first_join =
      authenticated_conn(member_token)
      |> post("/api/v1/channels/#{channel["data"]["id"]}/join")
      |> json_response(201)

    refute first_join["replayed"]
    assert first_join["data"]["conversation"]["id"] == channel["data"]["id"]
    assert first_join["data"]["membership"]["role"] == "member"
    membership_id = first_join["data"]["membership"]["id"]
    membership_version = first_join["data"]["membership"]["version"]

    repeated_join =
      authenticated_conn(member_token)
      |> post("/api/v1/channels/#{channel["data"]["id"]}/join")
      |> json_response(200)

    assert repeated_join["replayed"]
    assert repeated_join["data"]["membership"]["id"] == membership_id
    assert repeated_join["data"]["membership"]["version"] == membership_version

    stale_leave =
      authenticated_conn(member_token)
      |> delete("/api/v1/channels/#{channel["data"]["id"]}/membership", %{
        version: membership_version + 1
      })

    assert json_response(stale_leave, 409)["error"]["code"] == "stale_version"

    first_leave =
      authenticated_conn(member_token)
      |> delete("/api/v1/channels/#{channel["data"]["id"]}/membership", %{
        version: membership_version
      })
      |> json_response(200)

    refute first_leave["replayed"]
    assert first_leave["data"]["membership"]["id"] == membership_id
    assert first_leave["data"]["membership"]["version"] == membership_version + 1

    repeated_leave =
      authenticated_conn(member_token)
      |> delete("/api/v1/channels/#{channel["data"]["id"]}/membership", %{
        version: membership_version
      })
      |> json_response(200)

    assert repeated_leave["replayed"]
    assert repeated_leave["data"]["membership"]["id"] == membership_id

    assert member["data"]["id"]
    assert build_conn() |> get("/api/v1/channels/discover") |> response(401)
  end

  defp authenticated_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
