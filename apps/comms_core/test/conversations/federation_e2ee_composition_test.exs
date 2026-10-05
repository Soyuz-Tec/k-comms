defmodule CommsCore.Conversations.FederationE2EECompositionTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Conversations}
  alias CommsCore.Accounts.MatrixProvisioningReceipt
  alias CommsCore.Conversations.PrivateRoomControlReceipt
  alias CommsTestSupport.Fixtures
  @moduletag :integration

  defmodule IdentityProvider do
    @behaviour CommsCore.Accounts.MatrixProvisioningPort.Contract
    def execute(:provision, command) do
      if Process.get(:federation_identity_unknown_ack),
        do: {:error, :matrix_provider_unavailable},
        else: {:ok, %MatrixProvisioningReceipt{matrix_user_id: command.matrix_user_id}}
    end

    def execute(action, command) when action in [:login, :refresh],
      do:
        {:ok,
         %MatrixProvisioningReceipt{
           matrix_user_id: command.matrix_user_id,
           matrix_device_id: command.matrix_device_id,
           access_token: "synthetic-client-auth-token",
           refresh_token: "synthetic-client-refresh-token",
           expires_in_ms: 180_000
         }}
  end

  defmodule RoomProvider do
    @behaviour CommsCore.Conversations.PrivateRoomControlPort.Contract
    def execute(:provision, command),
      do:
        {:ok,
         %PrivateRoomControlReceipt{
           matrix_room_id: "!" <> command.conversation_id <> ":example.org"
         }}
  end

  defmodule BridgeProvider do
    @behaviour CommsCore.Conversations.Federation.ProviderPort
    def perform(request) do
      send(self(), {:federation_effect, request.operation, request.transaction_id})
      {:error, :unexpected_federation_effect}
    end
  end

  setup do
    settings = %{
      federation_enabled: true,
      federation_envelope_key: :crypto.strong_rand_bytes(32),
      federation_homeserver_origin: "https://matrix.example.org",
      federation_server_name: "example.org",
      federation_bridge_user: "@bridge:example.org",
      federation_provider_adapter: BridgeProvider,
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
    subject = Fixtures.step_up(account)

    assert {:ok, _} =
             Conversations.put_federation_trust(
               %{
                 domain: "remote.example.org",
                 residency: "Synthetic region",
                 cross_border_reason: "Reviewed synthetic federation processing",
                 enabled: true
               },
               subject
             )

    %{account: account, subject: subject}
  end

  test "admission uses the actual ready-only Identity owner and preserves immutable provider control",
       c do
    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    assert Conversations.rollback_federation_hazard_count() == 1
    assert {:ok, _} = Accounts.matrix_client_session(c.subject)
    assert {:ok, identity} = Accounts.matrix_identity_view(c.account.tenant.id, c.account.user.id)
    assert identity.provisioning_state == :ready

    assert {:error, :not_found} =
             Accounts.matrix_identity_view(Ecto.UUID.generate(), c.account.user.id)

    Application.put_env(
      :comms_core,
      :federation_homeserver_origin,
      "https://replacement.example.org"
    )

    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    Application.put_env(:comms_core, :federation_homeserver_origin, "https://matrix.example.org")
    Application.put_env(:comms_core, :federation_server_name, "replacement.example.org")
    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    Application.put_env(:comms_core, :federation_server_name, "example.org")
    assert {:ok, room} = create_bridge(c)
    assert room.conversation_id == c.account.conversation.id
    refute Map.has_key?(Map.from_struct(room), :provider_bridge_user)
    refute Map.has_key?(Map.from_struct(room), :access_token)
    refute_received {:federation_effect, _, _}
  end

  test "unknown identity provisioning ACK cannot admit a plaintext bridge", c do
    Process.put(:federation_identity_unknown_ack, true)
    assert {:error, _} = Accounts.matrix_client_session(c.subject)

    assert {:error, :not_found} =
             Accounts.matrix_identity_view(c.account.tenant.id, c.account.user.id)

    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    assert Conversations.rollback_federation_hazard_count() == 1
    refute_received {:federation_effect, _, _}
  end

  test "actual private-room owner creation denies every plaintext Federation operation without writes",
       c do
    assert {:ok, _} = Accounts.matrix_client_session(c.subject)
    peer = Fixtures.user_fixture(c.account)

    peer_subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(
        c.account,
        peer.user,
        "Federation private peer"
      )

    assert {:ok, _} = Accounts.matrix_client_session(peer_subject)

    assert {:ok, private} =
             Conversations.create_private_room(
               %{
                 id: Ecto.UUID.generate(),
                 title: "Synthetic encrypted room",
                 member_ids: [peer.user.id]
               },
               c.subject
             )

    assert {:ok, conversation} = Conversations.get_for_user_view(private.id, c.subject)
    assert conversation.content_mode == :matrix_e2ee
    count = Conversations.rollback_federation_hazard_count()

    assert {:error, :encrypted_conversation_bridge_refused} = create_bridge(c, private.id)

    assert {:error, :private_room_requires_encrypted_client} =
             Conversations.federation_room(private.id, c.subject)

    assert {:error, :not_found} =
             Conversations.send_federation_message(
               private.id,
               %{
                 version: 1,
                 body: "plaintext must not cross",
                 idempotency_key: Ecto.UUID.generate()
               },
               c.subject
             )

    assert {:error, :not_found} =
             Conversations.invite_federation_participant(
               private.id,
               %{
                 version: 1,
                 matrix_user_id: "@person:remote.example.org"
               },
               c.subject
             )

    assert {:error, :not_found} = Conversations.federation_timeline(private.id, %{}, c.subject)
    assert {:error, :not_found} = Conversations.export_federation_metadata(private.id, c.subject)
    assert Conversations.rollback_federation_hazard_count() == count
    refute_received {:federation_effect, _, _}
  end

  defp create_bridge(c, id \\ nil),
    do:
      Conversations.create_federation_room(
        id || c.account.conversation.id,
        %{
          domain: "remote.example.org",
          plaintext_disclosure_accepted: true
        },
        c.subject
      )
end
