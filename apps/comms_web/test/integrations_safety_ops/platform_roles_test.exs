defmodule CommsWeb.IntegrationsSafetyOps.PlatformRolesTest do
  use CommsWeb.IntegrationSafetyOpsCase

  import Ecto.Query, only: [from: 2]

  alias CommsCore.Accounts.PlatformRoleGrant
  alias CommsCore.Repo

  @moduletag :integration
  @moduletag :integrations
  @moduletag :administration

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
end
