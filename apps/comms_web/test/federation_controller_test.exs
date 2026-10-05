defmodule CommsWeb.FederationControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Conversations.Federation.Trust
  alias CommsTestSupport.Fixtures

  test "actual authenticated routes return private metadata and keep providers disabled" do
    account = Fixtures.account_fixture()
    path = "/api/v1/conversations/#{account.conversation.id}/federation"
    conn = auth(account) |> get(path)
    assert json_response(conn, 200) == %{"data" => nil}
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert build_conn() |> get(path) |> response(401)

    response =
      auth(account)
      |> post(path, %{domain: "remote.example.org", plaintext_disclosure_accepted: true})

    assert json_response(response, 503)["error"]["code"] == "federation_disabled"
    refute Repo.exists?(Trust)
  end

  test "the actual admin policy endpoint verifies the retained owner session" do
    account = Fixtures.account_fixture()

    attrs = %{
      domain: "remote.example.org",
      residency: "Synthetic region",
      cross_border_reason: "Reviewed synthetic processing",
      enabled: true
    }

    denied = auth(account) |> put("/api/v1/admin/federation/trusts", attrs)
    assert json_response(denied, 428)["error"]["code"] == "step_up_required"
    assert get_resp_header(denied, "cache-control") == ["private, no-store"]
    Fixtures.step_up(account)
    saved = auth(account) |> put("/api/v1/admin/federation/trusts", attrs) |> json_response(200)
    assert saved["data"]["residency_verified"] == false

    assert Enum.sort(Map.keys(saved["data"])) ==
             ~w(cross_border_reason domain enabled id residency residency_verified version)

    assert {:ok, trusts} = Conversations.federation_trusts(Fixtures.subject(account))
    assert length(trusts) == 1
  end

  test "a foreign tenant cannot read another conversation's bridge or invite its principals" do
    account = Fixtures.account_fixture()
    foreign = Fixtures.account_fixture()
    path = "/api/v1/conversations/#{account.conversation.id}/federation"
    assert auth(foreign) |> get(path) |> response(403)

    response =
      auth(foreign)
      |> post(path <> "/invitations", %{version: 1, matrix_user_id: "@person:remote.example.org"})

    assert json_response(response, 503)["error"]["code"] == "federation_disabled"
    refute Repo.exists?(Trust)
  end

  defmodule IdentityProvider do
    @behaviour CommsCore.Accounts.MatrixProvisioningPort.Contract
    def execute(:provision, c),
      do: {:ok, %CommsCore.Accounts.MatrixProvisioningReceipt{matrix_user_id: c.matrix_user_id}}

    def execute(:login, c),
      do:
        {:ok,
         %CommsCore.Accounts.MatrixProvisioningReceipt{
           matrix_user_id: c.matrix_user_id,
           matrix_device_id: c.matrix_device_id,
           access_token: "synthetic-controller-client-token",
           refresh_token: "synthetic-controller-refresh-token",
           expires_in_ms: 180_000
         }}
  end

  defmodule RoomProvider do
    @behaviour CommsCore.Conversations.PrivateRoomControlPort.Contract
    def execute(:provision, c),
      do:
        {:ok,
         %CommsCore.Conversations.PrivateRoomControlReceipt{
           matrix_room_id: "!" <> c.conversation_id <> ":example.org"
         }}
  end

  test "actual encrypted-room HTTP admission cannot create or read a plaintext bridge" do
    settings = %{
      federation_enabled: true,
      federation_envelope_key: :crypto.strong_rand_bytes(32),
      federation_homeserver_origin: "https://matrix.example.org",
      federation_server_name: "example.org",
      federation_bridge_user: "@bridge:example.org",
      matrix_client_provisioning_enabled: true,
      private_rooms_enabled: true,
      matrix_provisioning_adapter: IdentityProvider,
      private_room_control_adapter: RoomProvider,
      identity_secret_encryption_key: :crypto.strong_rand_bytes(32),
      matrix_identity_provider: %{
        issuer: "https://matrix.example.org",
        server_name: "example.org",
        control_user_id: "@control:example.org"
      }
    }

    previous =
      Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    account = Fixtures.account_fixture()
    peer = Fixtures.user_fixture(account)
    subject = Fixtures.step_up(account)

    peer_subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(
        account,
        peer.user,
        "Encrypted HTTP peer"
      )

    assert {:ok, _} = CommsCore.Accounts.matrix_client_session(subject)
    assert {:ok, _} = CommsCore.Accounts.matrix_client_session(peer_subject)

    assert {:ok, _} =
             Conversations.put_federation_trust(
               %{
                 domain: "remote.example.org",
                 residency: "Synthetic region",
                 cross_border_reason: "Reviewed synthetic processing",
                 enabled: true
               },
               subject
             )

    assert {:ok, room} =
             Conversations.create_private_room(
               %{
                 id: Ecto.UUID.generate(),
                 title: "Encrypted HTTP room",
                 member_ids: [peer.user.id]
               },
               subject
             )

    count = Conversations.rollback_federation_hazard_count()
    path = "/api/v1/conversations/#{room.id}/federation"

    response =
      auth(account)
      |> post(path, %{domain: "remote.example.org", plaintext_disclosure_accepted: true})

    assert json_response(response, 409)["error"]["code"] ==
             "encrypted_conversation_bridge_refused"

    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    response = auth(account) |> get(path)

    assert json_response(response, 409)["error"]["code"] ==
             "private_room_requires_encrypted_client"

    assert Conversations.rollback_federation_hazard_count() == count
  end

  defp auth(account) do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end
end
