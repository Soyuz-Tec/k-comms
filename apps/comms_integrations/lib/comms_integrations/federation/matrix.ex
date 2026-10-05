defmodule CommsIntegrations.Federation.Matrix do
  @moduledoc "Matrix v3 client-server bridge over the existing DNS-pinned, TLS-verifying transport."
  @behaviour CommsCore.Conversations.Federation.ProviderPort
  alias CommsCore.Conversations.Federation.{ProviderRequest, ProviderReceipt}
  alias CommsIntegrations.Federation.Domain
  alias CommsIntegrations.PinnedHttp
  @impl true
  def perform(%ProviderRequest{} = request) do
    with {:ok, config} <- configured(),
         :ok <- provider_binding(request, config),
         true <- request.deadline > System.monotonic_time(:millisecond) do
      with {:ok, %{"user_id" => principal}} <- call(:get, "/account/whoami", nil, request, config),
           true <- principal == config.bridge_user do
        case execute(request, config) do
          {:ok, result} when is_map(result) ->
            {:ok, struct!(ProviderReceipt, Map.put(result, :operation, request.operation))}

          {:error, _} = error ->
            error

          _ ->
            {:error, :invalid_matrix_response}
        end
      else
        _ -> {:error, :matrix_bridge_principal_mismatch}
      end
    else
      false -> {:error, :federation_deadline}
      error -> error
    end
  rescue
    _ -> {:error, :federation_provider_unavailable}
  end

  def perform(_), do: {:error, :invalid_federation_request}

  defp provider_binding(request, config) do
    if request.homeserver_origin == config.origin and request.server_name == config.server_name,
      do: :ok,
      else: {:error, :federation_provider_identity_changed}
  end

  defp execute(%{operation: :create} = r, c) do
    alias_name = "#" <> r.alias_localpart <> ":" <> c.server_name
    # createRoom has no transaction-id endpoint. Resolve the durable owned alias
    # before every attempt; lost create acknowledgement never permits a blind retry.
    case call(:get, "/directory/room/" <> segment(alias_name), nil, r, c) do
      {:ok, %{"room_id" => room}} ->
        owned_room(room, r, c)

      {:error, :matrix_not_found} when r.body == "first_attempt" ->
        initial = [
          %{
            "type" => "org.kcomms.bridge",
            "state_key" => "",
            "content" => %{"lineage" => r.alias_localpart}
          },
          %{
            "type" => "m.room.server_acl",
            "state_key" => "",
            "content" => %{
              "allow" => [c.server_name | r.allowed_servers],
              "deny" => [],
              "allow_ip_literals" => false
            }
          },
          %{
            "type" => "m.room.guest_access",
            "state_key" => "",
            "content" => %{"guest_access" => "forbidden"}
          },
          %{
            "type" => "m.room.power_levels",
            "state_key" => "",
            "content" => %{
              "users" => %{c.bridge_user => 100},
              "users_default" => 0,
              "events_default" => 0,
              "state_default" => 100,
              "invite" => 100,
              "kick" => 100,
              "ban" => 100,
              "redact" => 100,
              "events" => %{"m.room.encryption" => 100}
            }
          }
        ]

        case call(
               :post,
               "/createRoom",
               %{
                 "room_alias_name" => r.alias_localpart,
                 "preset" => "private_chat",
                 "visibility" => "private",
                 "creation_content" => %{"m.federate" => true},
                 "initial_state" => initial
               },
               r,
               c
             ) do
          {:ok, %{"room_id" => room}} -> owned_room(room, r, c)
          _ -> {:error, :federation_create_uncertain}
        end

      _ ->
        {:error, :federation_create_uncertain}
    end
  end

  defp execute(%{operation: :invite, room_id: room, principal: principal} = r, c) do
    with :ok <- safe_room(room, r, c),
         {:ok, _} <- call(:post, room_path(room) <> "/invite", %{"user_id" => principal}, r, c),
         {:ok, members} <- joined(room, r, c) do
      {:ok, %{state: if(principal in members, do: "joined", else: "invited")}}
    end
  end

  defp execute(%{operation: :send, room_id: room, body: body} = r, c) do
    with :ok <- safe_room(room, r, c),
         {:ok, members} <- joined(room, r, c),
         true <- Enum.all?(members, &(&1 in [c.bridge_user | r.allowed_principals])),
         {:ok, %{"event_id" => event}} <-
           call(
             :put,
             room_path(room) <> "/send/m.room.message/" <> segment(r.transaction_id),
             %{
               "msgtype" => "m.text",
               "body" => "K-Comms plaintext bridge (explicit member consent):\n" <> body
             },
             r,
             c
           ) do
      {:ok, %{event_id: event}}
    end
  end

  defp execute(%{operation: :timeline, room_id: room} = r, c) do
    with :ok <- safe_room(room, r, c),
         {:ok, members} <- joined(room, r, c),
         true <- Enum.all?(members, &(&1 in [c.bridge_user | r.allowed_principals])),
         {:ok, data} <-
           call(
             :get,
             room_path(room) <>
               "/messages?dir=b&limit=" <>
               Integer.to_string(min(r.limit || 30, 50)) <> cursor_query(r.cursor),
             nil,
             r,
             c
           ),
         {:ok, events} <- plaintext_events(data["chunk"], members),
         true <- is_nil(data["end"]) or valid_cursor?(data["end"]) do
      {:ok, %{events: events, cursor: Map.get(data, "end"), joined: members}}
    else
      false -> {:error, :untrusted_matrix_membership}
      error -> error
    end
  end

  defp execute(%{operation: :recover_event, room_id: room, source_transaction_id: txn} = r, c),
    do: recover_event(room, txn, nil, 3, r, c)

  defp execute(%{operation: :redact, room_id: room, event_id: event} = r, c) do
    with {:ok, _} <-
           call(
             :put,
             room_path(room) <> "/redact/" <> segment(event) <> "/" <> segment(r.transaction_id),
             %{"reason" => "K-Comms consent withdrawal or Governance deletion"},
             r,
             c
           ),
         {:ok, observed} <- call(:get, room_path(room) <> "/event/" <> segment(event), nil, r, c),
         true <- is_map(get_in(observed, ["unsigned", "redacted_because"])) do
      {:ok, %{local_redaction_observed: true, remote_deletion_confirmed: false}}
    else
      _ -> {:error, :federation_redaction_unconfirmed}
    end
  end

  defp execute(%{operation: :leave, room_id: room, principal: principal} = r, c) do
    # A lost kick acknowledgement is recovered from standard membership state.
    # Joined-member absence alone is insufficient while an invitation survives.
    _ =
      call(
        :post,
        room_path(room) <> "/kick",
        %{"user_id" => principal, "reason" => "K-Comms consent withdrawn"},
        r,
        c
      )

    with {:ok, %{"membership" => membership}} <-
           call(:get, room_path(room) <> "/state/m.room.member/" <> segment(principal), nil, r, c),
         true <- membership in ["leave", "ban"],
         {:ok, members} <- joined(room, r, c),
         false <- principal in members do
      {:ok, %{local_absence_observed: true, remote_deletion_confirmed: false}}
    else
      _ -> {:error, :federation_member_absence_unconfirmed}
    end
  end

  defp execute(%{operation: :close, room_id: room} = r, c) do
    with {:ok, _} <- call(:post, room_path(room) <> "/leave", %{}, r, c) do
      # A successful local leave does not attest deletion at any federated server.
      {:ok, %{local_leave_observed: true, remote_deletion_confirmed: false}}
    end
  end

  defp execute(_, _), do: {:error, :invalid_federation_operation}

  defp recover_event(_, _, _, 0, _, _), do: {:error, :federation_send_outcome_unconfirmed}

  defp recover_event(room, txn, cursor, pages, r, c) do
    with {:ok, data} <-
           call(
             :get,
             room_path(room) <> "/messages?dir=b&limit=50" <> cursor_query(cursor),
             nil,
             r,
             c
           ),
         chunk when is_list(chunk) and length(chunk) <= 50 <- data["chunk"] do
      # Recover only the bot's standard Matrix unsigned.transaction_id metadata.
      # Never resend a body after withdrawal and never store response plaintext.
      case Enum.find(
             chunk,
             &(&1["sender"] == c.bridge_user and &1["type"] == "m.room.message" and
                 get_in(&1, ["unsigned", "transaction_id"]) == txn)
           ) do
        %{"event_id" => event} when is_binary(event) and byte_size(event) in 1..255 ->
          {:ok, %{event_id: event}}

        nil ->
          if valid_cursor?(data["end"]),
            do: recover_event(room, txn, data["end"], pages - 1, r, c),
            else: {:error, :federation_send_outcome_unconfirmed}
      end
    else
      _ -> {:error, :federation_send_outcome_unconfirmed}
    end
  end

  defp owned_room(room, r, c) do
    with :ok <- safe_room(room, r, c) do
      {:ok, %{room_id: room}}
    else
      _ -> {:error, :unowned_matrix_room}
    end
  end

  defp safe_room(room, r, c) when is_binary(room) and byte_size(room) <= 255 do
    with true <- String.starts_with?(room, "!"),
         {:ok, state} when is_list(state) and length(state) <= 1000 <-
           call(:get, room_path(room) <> "/state", nil, r, c),
         false <- Enum.any?(state, &(&1["type"] == "m.room.encryption")),
         true <-
           Enum.any?(
             state,
             &(&1["type"] == "m.room.join_rules" and
                 get_in(&1, ["content", "join_rule"]) == "invite")
           ),
         true <-
           Enum.any?(
             state,
             &(&1["type"] == "org.kcomms.bridge" and
                 get_in(&1, ["content", "lineage"]) == r.alias_localpart)
           ),
         true <-
           Enum.any?(state, &(&1["type"] == "m.room.create" and &1["sender"] == c.bridge_user)),
         true <-
           Enum.any?(
             state,
             &(&1["type"] == "m.room.guest_access" and
                 get_in(&1, ["content", "guest_access"]) == "forbidden")
           ),
         true <- safe_acl?(state, r, c),
         true <- safe_power?(state, c) do
      :ok
    else
      _ -> {:error, :encrypted_or_unsafe_matrix_room}
    end
  end

  defp safe_room(_, _, _), do: {:error, :invalid_matrix_room}

  defp safe_acl?(state, r, c) do
    expected = Enum.sort([c.server_name | r.allowed_servers])

    Enum.any?(state, fn e ->
      content = e["content"] || %{}

      e["type"] == "m.room.server_acl" and content["allow_ip_literals"] == false and
        content["deny"] == [] and is_list(content["allow"]) and
        Enum.sort(content["allow"]) == expected
    end)
  end

  defp safe_power?(state, c) do
    Enum.any?(state, fn e ->
      p = e["content"] || %{}
      users = p["users"] || %{}

      e["type"] == "m.room.power_levels" and users[c.bridge_user] == 100 and
        Enum.all?(Map.delete(users, c.bridge_user), fn {_, power} -> power == 0 end) and
        p["users_default"] == 0 and p["state_default"] == 100 and p["invite"] == 100 and
        p["kick"] == 100 and p["ban"] == 100 and p["redact"] == 100 and
        p["events"] == %{"m.room.encryption" => 100}
    end)
  end

  defp joined(room, r, c) do
    with {:ok, %{"joined" => members}} when is_map(members) <-
           call(:get, room_path(room) <> "/joined_members", nil, r, c),
         true <- map_size(members) <= 101 do
      {:ok, Map.keys(members)}
    else
      _ -> {:error, :unbounded_matrix_membership}
    end
  end

  defp plaintext_events(events, members) when is_list(events) and length(events) <= 50 do
    if Enum.any?(events, &(&1["type"] == "m.room.encrypted")) do
      {:error, :encrypted_matrix_event_refused}
    else
      {:ok,
       Enum.flat_map(events, fn event ->
         body = get_in(event, ["content", "body"])

         if event["type"] == "m.room.message" and event["sender"] in members and
              get_in(event, ["content", "msgtype"]) == "m.text" and is_binary(body) and
              byte_size(body) in 1..16_384 and is_binary(event["event_id"]) and
              byte_size(event["event_id"]) in 1..255 and is_integer(event["origin_server_ts"]) and
              event["origin_server_ts"] >= 0 do
           [
             %{
               event_id: event["event_id"],
               sender: event["sender"],
               body: body,
               timestamp: event["origin_server_ts"]
             }
           ]
         else
           []
         end
       end)}
    end
  end

  defp plaintext_events(_, _), do: {:error, :invalid_matrix_timeline}

  defp call(method, path, payload, r, c) do
    remaining = r.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :federation_deadline}
    else
      body = if is_nil(payload), do: "", else: Jason.encode!(payload)

      opts =
        [
          allowed_hosts: [c.host],
          allowed_ports: [443],
          timeout_ms: remaining,
          max_response_bytes: 262_144,
          max_response_header_bytes: 16_384,
          max_response_header_count: 50
        ] ++ Keyword.take(c.transport_options, [:resolver, :transport])

      with {:ok, %{status: status, body: raw}} <-
             PinnedHttp.request(
               method,
               c.origin <> "/_matrix/client/v3" <> path,
               [{"authorization", "Bearer " <> c.token}, {"content-type", "application/json"}],
               body,
               opts
             ) do
        cond do
          status in 200..299 -> Jason.decode(raw)
          status == 404 -> {:error, :matrix_not_found}
          status == 429 -> {:error, :matrix_rate_limited}
          status in [401, 403] -> {:error, :matrix_authorization_failed}
          true -> {:error, :matrix_effect_uncertain}
        end
      else
        _ -> {:error, :matrix_effect_uncertain}
      end
    end
  end

  defp configured do
    c = Application.get_env(:comms_integrations, :federation_matrix, %{})
    uri = URI.parse(Map.get(c, :origin, ""))

    with true <- Map.get(c, :enabled, false),
         true <- Map.get(c, :provider_qualified, false),
         "https" <- uri.scheme,
         nil <- uri.userinfo,
         nil <- uri.query,
         nil <- uri.fragment,
         path when path in [nil, "", "/"] <- uri.path,
         port when port in [nil, 443] <- uri.port,
         {:ok, host} <- Domain.validate(uri.host),
         true <- Map.get(c, :origin) == "https://" <> host,
         {:ok, server} <- Domain.validate(Map.get(c, :server_name)),
         {:ok, bridge} <- Domain.matrix_user(Map.get(c, :bridge_user), server),
         token when is_binary(token) and byte_size(token) in 16..4096 <- Map.get(c, :access_token),
         false <- Regex.match?(~r/[^\x21-\x7e]/, token) do
      {:ok,
       %{
         origin: "https://" <> host,
         host: host,
         server_name: server,
         bridge_user: bridge,
         token: token,
         transport_options: Map.get(c, :transport_options, [])
       }}
    else
      _ -> {:error, :federation_not_configured}
    end
  end

  defp room_path(room), do: "/rooms/" <> segment(room)
  defp valid_cursor?(value), do: is_binary(value) and byte_size(value) in 1..2048
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp cursor_query(nil), do: ""
  defp cursor_query(cursor), do: "&from=" <> segment(cursor)
end
