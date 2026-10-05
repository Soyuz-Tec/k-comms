defmodule CommsWeb.NativePushControllerTest.Provider do
  @behaviour CommsCore.Notifications.NativePushProviderPort.Contract
  def status, do: %{status: :available, channels: ["apns_voip"]}
  def deliver(_, _), do: raise("Registration HTTP must not send native push")
end

defmodule CommsWeb.NativePushControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.Session
  alias CommsTestSupport.Fixtures
  @moduletag :integration
  @moduletag :notifications

  setup do
    config = [
      native_push_enabled: true,
      native_push_encryption_key: :crypto.strong_rand_bytes(32),
      native_push_encryption_keys: nil,
      native_push_provider_adapter: __MODULE__.Provider,
      native_push_platforms: [
        %{
          platform: "ios",
          channel: "apns_voip",
          application_id: "com.synthetic.native",
          environment: "sandbox",
          device_qualified: true
        }
      ]
    ]

    previous = Map.new(config, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)
    Enum.each(config, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    %{account: account, token: token}
  end

  test "real native readiness stays default closed and anonymous callers cannot register", %{
    token: token
  } do
    Application.put_env(:comms_core, :native_push_enabled, false)

    assert %{"data" => %{"enabled" => false, "protocol_version" => 1}} =
             authenticated(token) |> get("/api/v1/me/native-push/config") |> json_response(200)

    assert authenticated(token)
           |> put("/api/v1/me/native-push/registration", attrs())
           |> json_response(409)

    assert build_conn()
           |> put("/api/v1/me/native-push/registration", attrs())
           |> json_response(401)
  end

  test "real registration routes return safe current-device receipts and reject stale CAS and expired sessions",
       %{account: account, token: token} do
    path = "/api/v1/me/native-push/registration"
    assert %{"data" => []} = authenticated(token) |> get(path) |> json_response(200)
    created = authenticated(token) |> put(path, attrs()) |> json_response(200)
    assert created["replayed"] == false
    assert created["data"]["device_id"] == account.device.id
    assert created["data"]["version"] == 1
    assert is_binary(created["data"]["expires_at"])
    refute Jason.encode!(created) =~ attrs().token

    refute Map.keys(created["data"])
           |> Enum.any?(
             &(&1 in ~w(token token_hash ciphertext nonce tag key_id user_id session_id))
           )

    replay =
      authenticated(token) |> put(path, %{attrs() | expected_version: 1}) |> json_response(200)

    assert replay["replayed"] == true
    assert replay["data"]["id"] == created["data"]["id"]
    listed = authenticated(token) |> get(path) |> json_response(200)
    assert listed["data"] == [created["data"]]

    assert authenticated(token)
           |> delete(path, %{channel: "apns_voip", expected_version: 2})
           |> json_response(409)

    revoked =
      authenticated(token)
      |> delete(path, %{channel: "apns_voip", expected_version: 1})
      |> json_response(200)

    assert revoked["data"]["status"] == "revoked"
    assert {:ok, _} = Accounts.access_context(account.session.id)

    Repo.get!(Session, account.session.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert authenticated(token) |> get(path) |> json_response(401)
  end

  defp authenticated(token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  defp attrs,
    do: %{
      platform: "ios",
      channel: "apns_voip",
      application_id: "com.synthetic.native",
      environment: "sandbox",
      token: String.duplicate("a", 64),
      installation_id: "00000000-0000-4000-8000-000000000001",
      expected_version: 0
    }
end
