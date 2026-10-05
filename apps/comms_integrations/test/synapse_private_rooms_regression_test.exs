defmodule CommsIntegrations.SynapsePrivateRoomsRegressionTest.Transport do
  @moduledoc false
  import ExUnit.Assertions

  def request(destination, method, headers, body, options) do
    assert destination.host == "matrix.example.test"
    assert destination.addresses == [{93, 184, 216, 34}]
    assert destination.port == 443
    assert options[:timeout_ms] > 0
    assert options[:timeout_ms] <= 2500

    assert List.keyfind(headers, "authorization", 0) ==
             {"authorization", "Bearer synthetic-device-less-control-token"}

    path = destination.uri.path
    calls = Process.get(:private_room_draft_calls, [])
    Process.put(:private_room_draft_calls, calls ++ [{method, path, body}])
    Process.get(:private_room_draft_handler).(method, path, body)
  end
end

defmodule CommsIntegrations.SynapsePrivateRoomsRegressionTest do
  use ExUnit.Case, async: false
  alias CommsCore.Accounts.MatrixIdentityView
  alias CommsCore.Conversations.{PrivateRoomControlCommand, PrivateRoomControlReceipt}
  alias CommsIntegrations.SynapsePrivateRooms
  alias CommsIntegrations.SynapsePrivateRoomsRegressionTest.Transport

  @moduletag :unit
  @moduletag :external_delivery

  @tenant "29c674da-03a8-4d04-8053-e7b43c5b4019"
  @conversation "e7821ac0-827d-41a9-bc6b-3f4ce09f75e8"
  @owner "cd59ed8f-2a5b-48df-988d-4e7bd1c9433b"
  @peer "46854832-2258-47e8-9136-6bca23c0e1e8"
  @issuer "https://matrix.example.test"
  @server "example.test"
  @control "@private-control:example.test"
  @owner_matrix "@kc_29c674da03a84d048053e7b43c5b4019_cd59ed8f2a5b48df988d4e7bd1c9433b:example.test"
  @peer_matrix "@kc_29c674da03a84d048053e7b43c5b4019_46854832225847e891366bca23c0e1e8:example.test"
  @room "!syntheticOwned:example.test"
  @room_alias "#kc_private_e7821ac0827d41a9bc6b3f4ce09f75e8:example.test"

  # Synthetic protocol regression. This exercises the real adapter and real PinnedHttp
  # policy with a recording synthetic transport. It does not prove independent
  # owner admission commits, real provider effects, cryptography or SDK behavior.
  setup do
    previous = Application.fetch_env(:comms_integrations, :synapse_private_rooms)

    config = %{
      homeserver_url: @issuer,
      server_name: @server,
      control_user_id: @control,
      control_token: "synthetic-device-less-control-token",
      transport_options: [
        resolver: fn "matrix.example.test", _deadline -> [{93, 184, 216, 34}] end,
        transport: Transport
      ]
    }

    Application.put_env(:comms_integrations, :synapse_private_rooms, config)
    Process.put(:private_room_draft_calls, [])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:comms_integrations, :synapse_private_rooms, value)
        :error -> Application.delete_env(:comms_integrations, :synapse_private_rooms)
      end
    end)

    :ok
  end

  test "lost first creation ACK followed by alias 404 never performs another create" do
    handler(fn
      :get, path, _body ->
        if alias_path?(path), do: error_response(404), else: native_response(path, owned_state())

      :post, "/_matrix/client/v3/createRoom", body ->
        expected_alias =
          @room_alias |> String.trim_leading("#") |> String.split(":", parts: 2) |> hd()

        assert Jason.decode!(body)["room_alias_name"] == expected_alias
        {:error, :outbound_timeout}

      :post, "/_matrix/client/v3/keys/query", _body ->
        ok(empty_public_keys())

      method, path, _body ->
        flunk("unexpected native effect #{method} #{path}")
    end)

    assert {:error, _} =
             SynapsePrivateRooms.execute(
               :provision,
               command(allow_create?: true, matrix_room_id: nil)
             )

    assert create_count() == 1

    for _ <- 1..2 do
      assert {:error, _} =
               SynapsePrivateRooms.execute(
                 :provision,
                 command(allow_create?: false, matrix_room_id: nil)
               )

      assert create_count() == 1
    end

    assert mutation_paths() == [:create]
  end

  test "cleanup alias 404 never creates, invites or treats absence as completed purge" do
    install_owned_handler(alias_status: 404)
    assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
    assert mutation_paths() == []
  end

  test "owned recovery uses native full-state array and v11 creation event sender" do
    install_owned_handler()

    assert {:ok, %PrivateRoomControlReceipt{matrix_room_id: @room} = receipt} =
             SynapsePrivateRooms.execute(:recover_room, command())

    refute receipt.provider_purged? == true

    assert Enum.any?(calls(), fn {method, path, _} ->
             method == :get and String.ends_with?(path, "/state")
           end)

    refute Enum.any?(owned_state(), fn event ->
             event["type"] == "m.room.create" and Map.has_key?(event["content"], "creator")
           end)

    assert mutation_paths() == []
  end

  test "a same-server alias target owned by a foreign creator is never adopted or purged" do
    state =
      update_event(
        owned_state(),
        "m.room.create",
        &Map.put(&1, "sender", "@foreign:example.test")
      )

    install_owned_handler(state: state)
    assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
    assert mutation_paths() == []

    clear_calls()
    assert {:error, _} = SynapsePrivateRooms.execute(:purge, command())
    assert mutation_paths() == []
  end

  test "tenant, conversation, alias and protocol lineage changes refuse native adoption" do
    for {key, value} <- [
          {"tenant_id", "c7681c92-5baa-495d-9dd4-148d934d580d"},
          {"conversation_id", "d188f2de-08d3-41ed-a8dd-16471558cafe"},
          {"room_alias", "#another:example.test"},
          {"protocol", "plaintext_v1"}
        ] do
      clear_calls()
      state = update_content(owned_state(), "com.k_comms.private_scope", &Map.put(&1, key, value))
      install_owned_handler(state: state)
      assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
      assert mutation_paths() == []
    end

    clear_calls()

    state =
      update_event(
        owned_state(),
        "com.k_comms.private_scope",
        &Map.put(&1, "sender", @peer_matrix)
      )

    install_owned_handler(state: state)
    assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
    assert mutation_paths() == []
  end

  test "missing or downgraded privacy state refuses recovery before mutation" do
    variants = [
      Enum.reject(owned_state(), &(&1["type"] == "com.k_comms.private_scope")),
      Enum.reject(owned_state(), &(&1["type"] == "m.room.encryption")),
      update_content(owned_state(), "m.room.create", &Map.put(&1, "m.federate", true)),
      update_content(owned_state(), "m.room.encryption", &Map.put(&1, "algorithm", "plaintext")),
      update_content(
        owned_state(),
        "m.room.encryption",
        &Map.put(&1, "rotation_period_msgs", 101)
      ),
      update_content(
        owned_state(),
        "m.room.encryption",
        &Map.put(&1, "rotation_period_ms", 3_600_001)
      ),
      update_content(
        owned_state(),
        "m.room.history_visibility",
        &Map.put(&1, "history_visibility", "world_readable")
      ),
      update_content(
        owned_state(),
        "m.room.guest_access",
        &Map.put(&1, "guest_access", "can_join")
      ),
      update_content(owned_state(), "m.room.join_rules", &Map.put(&1, "join_rule", "public")),
      update_content(owned_state(), "m.room.power_levels", &Map.put(&1, "events_default", 0)),
      update_content(owned_state(), "m.room.power_levels", &Map.put(&1, "state_default", 0)),
      update_content(
        owned_state(),
        "m.room.power_levels",
        &put_in(&1, ["events", "m.room.message"], 0)
      ),
      update_content(
        owned_state(),
        "m.room.power_levels",
        &put_in(&1, ["users", @peer_matrix], 100)
      )
    ]

    for state <- variants do
      clear_calls()
      install_owned_handler(state: state)
      assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
      assert mutation_paths() == []
    end
  end

  test "unexpected joined or invited identity blocks recovery even when privacy state otherwise matches" do
    for state <- [
          owned_state() ++
            [event("m.room.member", "@unknown:example.test", %{"membership" => "join"})],
          owned_state() ++
            [event("m.room.member", "@unknown:example.test", %{"membership" => "invite"})]
        ] do
      clear_calls()
      install_owned_handler(state: state)
      assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
      assert mutation_paths() == []
    end
  end

  test "provider origin, independent server name and control identity remain bound with empty active roster" do
    for command <- [
          command(members: [], provider_issuer: "https://other.example.test"),
          command(members: [], provider_server_name: "other.example.test"),
          command(members: [], control_matrix_user_id: "@different:example.test")
        ] do
      clear_calls()
      handler(fn _, _, _ -> flunk("changed immutable provider binding reached HTTP") end)
      assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command)
      assert calls() == []
    end
  end

  test "control device or any public signing identity blocks before room adoption" do
    for key_map <- [
          put_in(empty_public_keys(), ["device_keys", @control], %{"UNEXPECTED" => %{}}),
          put_in(empty_public_keys(), ["master_keys", @control], %{"keys" => %{}}),
          put_in(empty_public_keys(), ["self_signing_keys", @control], %{"keys" => %{}}),
          put_in(empty_public_keys(), ["user_signing_keys", @control], %{"keys" => %{}})
        ] do
      clear_calls()
      install_owned_handler(keys: key_map)
      assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
      refute Enum.any?(calls(), fn {_method, path, _} -> alias_path?(path) end)
      assert mutation_paths() == []
    end

    clear_calls()
    install_owned_handler(devices: %{"total" => 1, "devices" => [%{"device_id" => "UNEXPECTED"}]})
    assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
    assert mutation_paths() == []
  end

  test "malformed key inventory is not proof that server control has no crypto keys" do
    install_owned_handler(keys: %{})
    assert {:error, _} = SynapsePrivateRooms.execute(:recover_room, command())
    refute Enum.any?(calls(), fn {_method, path, _} -> alias_path?(path) end)
    assert mutation_paths() == []
  end

  test "expired total deadline cannot issue even a provider identity read" do
    handler(fn _, _, _ -> flunk("expired operation reached HTTP") end)

    assert {:error, _} =
             SynapsePrivateRooms.execute(
               :recover_room,
               command(deadline: System.monotonic_time(:millisecond) - 1)
             )

    assert calls() == []
  end

  defp command(attrs \\ []) do
    defaults = %PrivateRoomControlCommand{
      tenant_id: @tenant,
      conversation_id: @conversation,
      room_alias: @room_alias,
      members: [identity(@owner, @owner_matrix), identity(@peer, @peer_matrix)],
      generation: 1,
      matrix_room_id: @room,
      provider_issuer: @issuer,
      provider_server_name: @server,
      control_matrix_user_id: @control,
      historical_matrix_user_ids: [@owner_matrix, @peer_matrix],
      deadline: System.monotonic_time(:millisecond) + 15_000,
      allow_create?: false
    }

    struct!(defaults, attrs)
  end

  defp identity(user, principal),
    do: %MatrixIdentityView{
      tenant_id: @tenant,
      user_id: user,
      issuer: @issuer,
      matrix_user_id: principal,
      provisioning_state: :ready
    }

  defp handler(fun), do: Process.put(:private_room_draft_handler, fun)
  defp calls, do: Process.get(:private_room_draft_calls, [])
  defp clear_calls, do: Process.put(:private_room_draft_calls, [])

  defp create_count,
    do:
      Enum.count(calls(), fn {method, path, _} ->
        method == :post and path == "/_matrix/client/v3/createRoom"
      end)

  defp alias_path?(path), do: String.starts_with?(path, "/_matrix/client/v3/directory/room/")
  defp ok(body), do: {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}

  defp error_response(status),
    do:
      {:ok,
       %{
         status: status,
         headers: [],
         body: Jason.encode!(%{"errcode" => "M_NOT_FOUND", "error" => "synthetic absent alias"})
       }}

  defp mutation_paths do
    Enum.flat_map(calls(), fn
      {:post, "/_matrix/client/v3/createRoom", _} ->
        [:create]

      {method, path, _} when method in [:put, :delete] ->
        [{method, path}]

      {:post, path, _} ->
        if String.ends_with?(path, "/invite") or String.ends_with?(path, "/ban"),
          do: [{:post, path}],
          else: []

      _ ->
        []
    end)
  end

  defp install_owned_handler(options \\ []) do
    state = Keyword.get(options, :state, owned_state())

    handler(fn
      :post, "/_matrix/client/v3/keys/query", _ ->
        ok(Keyword.get(options, :keys, empty_public_keys()))

      :get, path, _ ->
        cond do
          alias_path?(path) ->
            if Keyword.get(options, :alias_status, 200) == 200,
              do: ok(%{"room_id" => @room}),
              else: error_response(404)

          String.ends_with?(path, "/devices") ->
            ok(Keyword.get(options, :devices, %{"total" => 0, "devices" => []}))

          String.ends_with?(path, "/joined_members") ->
            ok(%{"joined" => Keyword.get(options, :joined, joined())})

          true ->
            native_response(path, state)
        end

      method, path, _ ->
        flunk("unexpected native mutation #{method} #{path}")
    end)
  end

  defp native_response(path, state) do
    cond do
      String.ends_with?(path, "/account/whoami") -> ok(%{"user_id" => @control})
      String.ends_with?(path, "/devices") -> ok(%{"total" => 0, "devices" => []})
      String.ends_with?(path, "/state") -> ok(state)
      String.ends_with?(path, "/joined_members") -> ok(%{"joined" => joined()})
      true -> flunk("unexpected native read #{path}; use standard full-state response")
    end
  end

  defp empty_public_keys,
    do: %{
      "device_keys" => %{@control => %{}},
      "master_keys" => %{},
      "self_signing_keys" => %{},
      "user_signing_keys" => %{}
    }

  defp joined, do: %{@control => %{}, @owner_matrix => %{}}

  defp owned_state do
    [
      event("m.room.create", "", %{"room_version" => "11", "m.federate" => false}),
      event("com.k_comms.private_scope", "", %{
        "tenant_id" => @tenant,
        "conversation_id" => @conversation,
        "room_alias" => @room_alias,
        "protocol" => "matrix_megolm_v1"
      }),
      event("m.room.encryption", "", %{
        "algorithm" => "m.megolm.v1.aes-sha2",
        "rotation_period_msgs" => 100,
        "rotation_period_ms" => 3_600_000
      }),
      event("m.room.history_visibility", "", %{"history_visibility" => "joined"}),
      event("m.room.guest_access", "", %{"guest_access" => "forbidden"}),
      event("m.room.join_rules", "", %{"join_rule" => "invite"}),
      event("m.room.power_levels", "", %{
        "users" => %{@control => 100},
        "users_default" => 0,
        "events_default" => 100,
        "state_default" => 100,
        "ban" => 100,
        "kick" => 100,
        "redact" => 100,
        "invite" => 100,
        "events" => %{"m.room.encrypted" => 0}
      }),
      event("m.room.member", @control, %{"membership" => "join"}),
      event("m.room.member", @owner_matrix, %{"membership" => "join"}),
      event("m.room.member", @peer_matrix, %{"membership" => "invite"})
    ]
  end

  defp event(type, key, content),
    do: %{"type" => type, "state_key" => key, "sender" => @control, "content" => content}

  defp update_event(state, type, fun),
    do: Enum.map(state, fn event -> if event["type"] == type, do: fun.(event), else: event end)

  defp update_content(state, type, fun),
    do: update_event(state, type, fn event -> Map.update!(event, "content", fun) end)
end
