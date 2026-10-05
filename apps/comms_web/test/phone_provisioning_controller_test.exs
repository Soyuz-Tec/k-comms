defmodule CommsWeb.PhoneProvisioningControllerTest do
  use CommsWeb.ConnCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsTestSupport.Fixtures

  setup do
    previous = Application.get_env(:comms_core, :telephony_provisioning_enabled)
    Application.put_env(:comms_core, :telephony_provisioning_enabled, false)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:comms_core, :telephony_provisioning_enabled),
        else: Application.put_env(:comms_core, :telephony_provisioning_enabled, previous)
    end)

    :ok
  end

  test "provider management endpoints reject unauthenticated calls" do
    assert build_conn() |> get("/api/v1/admin/telephony/provisioning") |> json_response(401)

    assert build_conn()
           |> post("/api/v1/admin/telephony/provisioning/inspect", %{})
           |> json_response(401)
  end

  test "current owner sees default-off readiness without provider credentials" do
    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/v1/admin/telephony/provisioning")

    assert %{
             "data" => %{
               "provider" => %{"enabled" => false, "ready" => false, "number_purchase" => false},
               "commands" => []
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "api_secret"
    refute conn.resp_body =~ "api_key"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "a valid human conversation-only session cannot read workspace provider setup" do
    account = Fixtures.account_fixture()

    account.user
    |> Ecto.Changeset.change(access_scope: :conversation_only)
    |> CommsCore.Repo.update!()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/v1/admin/telephony/provisioning")

    assert json_response(conn, 403)
  end
end
