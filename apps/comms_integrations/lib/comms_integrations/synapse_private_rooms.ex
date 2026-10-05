defmodule CommsIntegrations.SynapsePrivateRooms do
  @moduledoc "Native Matrix room control. Device-less server control has no crypto keys; participants can send only encrypted room events."
  @behaviour CommsCore.Conversations.PrivateRoomControlPort.Contract
  alias CommsCore.Conversations.{PrivateRoomControlCommand, PrivateRoomControlReceipt}
  alias CommsIntegrations.PinnedHttp

  def execute(action, %PrivateRoomControlCommand{} = command) do
    with {:ok, config} <- config(),
         :ok <- valid_command(command, config),
         config = Map.put(config, :deadline, command.deadline),
         :ok <- control_without_devices(config),
         do: dispatch(action, command, config)
  end

  defp dispatch(:provision, command, config) do
    alias_path = "/_matrix/client/v3/directory/room/" <> segment(command.room_alias)

    case request(config, :get, alias_path, nil) do
      {:ok, 200, %{"room_id" => room_id}} ->
        validate_room(config, command, room_id)

      {:ok, 404, _} when command.allow_create? == true ->
        local_alias =
          command.room_alias |> String.trim_leading("#") |> String.split(":", parts: 2) |> hd()

        levels = %{
          users: %{config.control_user_id => 100},
          users_default: 0,
          events_default: 100,
          state_default: 100,
          ban: 100,
          kick: 100,
          redact: 100,
          invite: 100,
          events: %{"m.room.encrypted" => 0}
        }

        body = %{
          room_alias_name: local_alias,
          visibility: "private",
          preset: "private_chat",
          invite: Enum.map(command.members, & &1.matrix_user_id),
          creation_content: %{"m.federate" => false},
          power_level_content_override: levels,
          initial_state: [
            %{type: "com.k_comms.private_scope", state_key: "", content: owned_scope(command)},
            %{
              type: "m.room.encryption",
              state_key: "",
              content: %{
                algorithm: "m.megolm.v1.aes-sha2",
                rotation_period_msgs: 100,
                rotation_period_ms: 3_600_000
              }
            },
            %{
              type: "m.room.history_visibility",
              state_key: "",
              content: %{history_visibility: "joined"}
            },
            %{type: "m.room.guest_access", state_key: "", content: %{guest_access: "forbidden"}}
          ]
        }

        with {:ok, 200, %{"room_id" => room_id}} <-
               request(config, :post, "/_matrix/client/v3/createRoom", body),
             do: validate_room(config, command, room_id)

      {:ok, 404, _} ->
        {:error, :private_room_creation_outcome_unknown}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :private_room_provisioning_unconfirmed}
    end
  end

  # Cleanup can recover an unknown creation ACK by immutable native alias.
  # This operation never creates a room or invites a participant.
  defp dispatch(:recover_room, command, config) do
    case request(
           config,
           :get,
           "/_matrix/client/v3/directory/room/" <> segment(command.room_alias),
           nil
         ) do
      {:ok, 200, %{"room_id" => room_id}} when is_binary(room_id) ->
        validate_room(config, command, room_id)

      _ ->
        {:error, :private_provider_room_identity_unconfirmed}
    end
  end

  defp dispatch(:remove_member, command, config) do
    path = "/_matrix/client/v3/rooms/" <> segment(command.matrix_room_id)
    # Ban also prevents rejoining through an old invitation after a lost ACK.
    with {:ok, 200, _} <-
           request(config, :post, path <> "/ban", %{
             user_id: command.removed_matrix_user_id,
             reason: "K-Comms private membership withdrawn"
           }),
         {:ok, 200, %{"membership" => "ban"}} <-
           request(
             config,
             :get,
             path <> "/state/m.room.member/" <> segment(command.removed_matrix_user_id),
             nil
           ) do
      validate_room(config, command, command.matrix_room_id)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :private_member_removal_unconfirmed}
    end
  end

  defp dispatch(:purge, command, config) do
    with {:ok, %PrivateRoomControlReceipt{}} <-
           validate_room(config, command, command.matrix_room_id),
         {:ok, 200, %{"delete_id" => id}} <-
           request(
             config,
             :delete,
             "/_synapse/admin/v2/rooms/" <> segment(command.matrix_room_id),
             %{block: true, purge: true}
           ) do
      {:ok,
       %PrivateRoomControlReceipt{
         matrix_room_id: command.matrix_room_id,
         purge_id: id,
         provider_purged?: false
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :private_room_purge_unconfirmed}
    end
  end

  defp dispatch(:purge_status, command, config) do
    with {:ok, 200, result} <-
           request(
             config,
             :get,
             "/_synapse/admin/v2/rooms/delete_status/" <> segment(command.purge_id),
             nil
           ),
         "complete" <- result["status"],
         [] <- get_in(result, ["shutdown_room", "failed_to_kick_users"]) || [] do
      {:ok,
       %PrivateRoomControlReceipt{
         matrix_room_id: command.matrix_room_id,
         purge_id: command.purge_id,
         provider_purged?: true
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :private_room_purge_unconfirmed}
    end
  end

  defp validate_room(config, command, id) do
    with true <-
           is_binary(id) and Regex.match?(~r/\A![^\s\x00-\x1f\x7f:]+:[^\s\x00-\x1f\x7f]+\z/u, id) and
             String.ends_with?(id, ":" <> command.provider_server_name),
         path = "/_matrix/client/v3/rooms/" <> segment(id),
         {:ok, 200, state} when is_list(state) <- request(config, :get, path <> "/state", nil),
         true <- length(state) in 5..500 and Enum.all?(state, &is_map/1),
         %{"sender" => creator, "content" => creation} <- state_event(state, "m.room.create", ""),
         true <- creator == command.control_matrix_user_id and creation["m.federate"] == false,
         %{"sender" => scope_sender, "content" => scope} <-
           state_event(state, "com.k_comms.private_scope", ""),
         true <- scope_sender == command.control_matrix_user_id and scope == owned_scope(command),
         %{"content" => encryption} <- state_event(state, "m.room.encryption", ""),
         true <-
           encryption["algorithm"] == "m.megolm.v1.aes-sha2" and
             encryption["rotation_period_msgs"] == 100 and
             encryption["rotation_period_ms"] == 3_600_000,
         %{"content" => %{"history_visibility" => "joined"}} <-
           state_event(state, "m.room.history_visibility", ""),
         %{"content" => %{"join_rule" => "invite"}} <- state_event(state, "m.room.join_rules", ""),
         %{"content" => %{"guest_access" => "forbidden"}} <-
           state_event(state, "m.room.guest_access", ""),
         %{"content" => levels} <- state_event(state, "m.room.power_levels", ""),
         true <- secure_levels?(levels, command.control_matrix_user_id),
         allowed = [command.control_matrix_user_id | command.historical_matrix_user_ids],
         members =
           Enum.filter(
             state,
             &(&1["type"] == "m.room.member" and
                 get_in(&1, ["content", "membership"]) in ["join", "invite"])
           ),
         true <- Enum.all?(members, &(&1["state_key"] in allowed)),
         true <-
           Enum.any?(
             members,
             &(&1["state_key"] == command.control_matrix_user_id and
                 get_in(&1, ["content", "membership"]) == "join")
           ) do
      {:ok,
       %PrivateRoomControlReceipt{
         matrix_room_id: id,
         joined_matrix_user_ids:
           for(m <- members, m["content"]["membership"] == "join", do: m["state_key"])
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :private_room_owned_protocol_unconfirmed}
    end
  end

  defp state_event(state, type, key) do
    case Enum.filter(state, &(&1["type"] == type and &1["state_key"] == key)) do
      [event] -> event
      _ -> nil
    end
  end

  defp owned_scope(command),
    do: %{
      "tenant_id" => command.tenant_id,
      "conversation_id" => command.conversation_id,
      "room_alias" => command.room_alias,
      "protocol" => "matrix_megolm_v1"
    }

  defp secure_levels?(levels, control) do
    levels["users"] == %{control => 100} and levels["users_default"] == 0 and
      levels["events_default"] == 100 and levels["state_default"] == 100 and
      levels["events"] == %{"m.room.encrypted" => 0} and
      Enum.all?(["ban", "kick", "redact", "invite"], &(levels[&1] == 100))
  end

  defp control_without_devices(config) do
    with {:ok, 200, %{"user_id" => _} = whoami} <-
           request(config, :get, "/_matrix/client/v3/account/whoami", nil),
         true <- whoami["user_id"] == config.control_user_id and whoami["device_id"] == nil,
         {:ok, 200, %{"total" => 0, "devices" => []}} <-
           request(
             config,
             :get,
             "/_synapse/admin/v2/users/" <> segment(config.control_user_id) <> "/devices",
             nil
           ),
         {:ok, 200, result} <-
           request(config, :post, "/_matrix/client/v3/keys/query", %{
             device_keys: %{config.control_user_id => []}
           }),
         true <-
           is_map(result) and is_map(result["device_keys"]) and
             (not Map.has_key?(result, "failures") or result["failures"] == %{}) and
             (not Map.has_key?(result["device_keys"], config.control_user_id) or
                result["device_keys"][config.control_user_id] == %{}) and
             Enum.all?(["master_keys", "self_signing_keys", "user_signing_keys"], fn section ->
               not Map.has_key?(result, section) or
                 (is_map(result[section]) and
                    not Map.has_key?(result[section], config.control_user_id))
             end) do
      :ok
    else
      _ -> {:error, :private_control_crypto_keys_forbidden}
    end
  end

  defp valid_command(command, config) do
    if is_integer(command.deadline) and command.deadline > System.monotonic_time(:millisecond) and
         command.provider_issuer == config.homeserver_url and
         command.provider_server_name == config.server_name and
         command.control_matrix_user_id == config.control_user_id and
         is_list(command.historical_matrix_user_ids) and
         length(command.historical_matrix_user_ids) in 1..100 and
         Enum.all?(
           command.historical_matrix_user_ids,
           &(is_binary(&1) and String.starts_with?(&1, "@") and
               String.ends_with?(&1, ":" <> config.server_name) and
               not Regex.match?(~r/[\x00-\x20\x7f]/u, &1))
         ) and
         command.room_alias ==
           "#kc_private_" <>
             String.replace(command.conversation_id, "-", "") <> ":" <> config.server_name and
         Enum.all?(
           command.members,
           &(&1.tenant_id == command.tenant_id and &1.issuer == config.homeserver_url and
               &1.provisioning_state == :ready)
         ), do: :ok, else: {:error, :private_room_provider_binding_invalid}
  end

  defp config do
    case Application.get_env(:comms_integrations, :synapse_private_rooms) do
      %{homeserver_url: url, server_name: name, control_user_id: user, control_token: token} =
          config
      when is_binary(url) and is_binary(name) and is_binary(user) and is_binary(token) and
             byte_size(token) > 0 ->
        uri = URI.parse(url)

        if uri.scheme == "https" and uri.userinfo == nil and uri.query == nil and
             uri.fragment == nil and uri.path in [nil, "", "/"] and is_binary(uri.host) and
             url == String.trim_trailing(url, "/") and
             not Regex.match?(~r/[\x00-\x20\x7f]/u, url <> name <> user <> token) and
             Regex.match?(~r/\A[A-Za-z0-9.-]+(?::[0-9]{1,5})?\z/, name) and
             String.starts_with?(user, "@") and String.ends_with?(user, ":" <> name),
           do: {:ok, config},
           else: {:error, :private_room_provider_configuration_invalid}

      _ ->
        {:error, :private_room_provider_unavailable}
    end
  end

  defp request(config, method, path, body) do
    uri = URI.parse(config.homeserver_url)
    remaining = config.deadline - System.monotonic_time(:millisecond)

    headers = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> config.control_token}
    ]

    if remaining <= 0 do
      {:error, :private_operation_timeout}
    else
      opts =
        Keyword.take(Map.get(config, :transport_options, []), [:resolver, :transport]) ++
          [
            allowed_hosts: [uri.host],
            allowed_ports: [uri.port || 443],
            timeout_ms: min(2500, remaining),
            deadline_ms: config.deadline,
            max_response_bytes: 131_072
          ]

      result =
        case PinnedHttp.request(
               method,
               String.trim_trailing(config.homeserver_url, "/") <> path,
               headers,
               if(body, do: Jason.encode!(body), else: ""),
               opts
             ) do
          {:ok, %{status: status, body: payload}} ->
            case Jason.decode(payload) do
              {:ok, result} when is_map(result) or is_list(result) -> {:ok, status, result}
              _ -> {:error, :private_room_provider_response_invalid}
            end

          _ ->
            {:error, :private_room_provider_unavailable}
        end

      if System.monotonic_time(:millisecond) >= config.deadline,
        do: {:error, :private_operation_timeout},
        else: result
    end
  end

  defp segment(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
