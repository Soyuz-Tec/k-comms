defmodule CommsIntegrations.FederationMatrixTest.Transport do
  def request(destination, method, _headers, body, options) do
    assert_public = hd(destination.addresses) == {93, 184, 216, 34}
    if not assert_public, do: raise("synthetic destination was not pinned")
    path = destination.uri.path
    send(self(), {:matrix_request, method, path, body, options[:timeout_ms]})
    handler = Process.get(:matrix_handler)
    handler.(method, path, body)
  end
end

defmodule CommsIntegrations.FederationMatrixTest do
  use ExUnit.Case, async: false
  alias CommsIntegrations.Federation.{Domain, Matrix}
  alias CommsCore.Conversations.Federation.{ProviderReceipt, ProviderRequest}
  @moduletag :unit
  @moduletag :external_delivery
  setup do
    previous = Application.get_env(:comms_integrations, :federation_matrix)

    Application.put_env(:comms_integrations, :federation_matrix, %{
      enabled: true,
      provider_qualified: true,
      origin: "https://matrix.example.org",
      server_name: "example.org",
      bridge_user: "@bridge:example.org",
      access_token: "synthetic-bridge-token-with-no-remote-account",
      transport_options: [
        resolver: fn _, _ -> [{93, 184, 216, 34}] end,
        transport: CommsIntegrations.FederationMatrixTest.Transport
      ]
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_integrations, :federation_matrix, previous),
        else: Application.delete_env(:comms_integrations, :federation_matrix)
    end)

    :ok
  end

  test "canonical domains refuse URL, email, IP, private suffix and alternate ports" do
    assert {:ok, "remote.example.org"} = Domain.validate("remote.example.org")

    for name <- [
          "REMOTE.example.org",
          "remote.example.org\n",
          "remote.example.org.",
          "127.0.0.1",
          "x.local",
          "https://remote.example.org",
          "remote.example.org:8448",
          "member@remote.example.org"
        ] do
      assert {:error, :invalid_federation_domain} = Domain.validate(name)
    end

    assert {:error, :untrusted_matrix_principal} =
             Domain.matrix_user("@person:other.example.org", "remote.example.org")

    assert {:error, :untrusted_matrix_principal} =
             Domain.matrix_user("@person:remote.example.org\n", "remote.example.org")
  end

  test "an encrypted room is refused before any send or timeline capture" do
    handler(fn :get, path, _ ->
      if String.ends_with?(path, "/account/whoami"),
        do: ok(%{"user_id" => "@bridge:example.org"}),
        else:
          ok(
            state() ++
              [
                %{
                  "type" => "m.room.encryption",
                  "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}
                }
              ]
          )
    end)

    for operation <- [:send, :invite, :timeline] do
      assert {:error, :encrypted_or_unsafe_matrix_room} = Matrix.perform(request(operation))
    end

    refute_received {:matrix_request, :put, _, _, _}
    refute_received {:matrix_request, :post, _, _, _}
  end

  test "lost create acknowledgement never permits a second blind create" do
    handler(fn
      :get, path, _ ->
        if String.ends_with?(path, "/account/whoami"),
          do: ok(%{"user_id" => "@bridge:example.org"}),
          else: {:ok, %{status: 404, body: "{}"}}

      :post, path, _ ->
        send(self(), {:create_attempt, path})
        {:error, :outbound_timeout}
    end)

    first = %{
      request(:create)
      | body: "first_attempt",
        allowed_servers: ["remote.example.org"]
    }

    assert {:error, :federation_create_uncertain} = Matrix.perform(first)
    assert_received {:create_attempt, "/_matrix/client/v3/createRoom"}

    assert {:error, :federation_create_uncertain} =
             Matrix.perform(%{first | body: "recovery_only"})

    refute_received {:create_attempt, _}
  end

  test "stable message transaction paths preserve the bridge disclosure and reject untrusted joined members" do
    handler(fn
      :get, path, _ ->
        cond do
          String.ends_with?(path, "/account/whoami") ->
            ok(%{"user_id" => "@bridge:example.org"})

          String.ends_with?(path, "/state") ->
            ok(state())

          String.ends_with?(path, "/joined_members") ->
            ok(%{
              "joined" => %{"@bridge:example.org" => %{}, "@person:remote.example.org" => %{}}
            })
        end

      :put, path, body ->
        send(self(), {:actual_send, path, Jason.decode!(body)})
        ok(%{"event_id" => "$synthetic-event"})
    end)

    r = %{request(:send) | allowed_principals: ["@person:remote.example.org"]}

    assert {:ok, %ProviderReceipt{event_id: "$synthetic-event", remote_deletion_confirmed: false}} =
             Matrix.perform(r)

    assert_received {:actual_send, path, payload}
    assert String.ends_with?(path, "/send/m.room.message/" <> r.transaction_id)

    assert payload["body"] ==
             "K-Comms plaintext bridge (explicit member consent):\nsynthetic text"

    assert {:error, :invalid_matrix_response} = Matrix.perform(%{r | allowed_principals: []})
    refute_received {:actual_send, _, _}
  end

  test "local observed redaction never becomes a remote deletion receipt" do
    handler(fn
      :get, path, _ ->
        cond do
          String.ends_with?(path, "/account/whoami") -> ok(%{"user_id" => "@bridge:example.org"})
          String.ends_with?(path, "/state") -> ok(state())
          true -> ok(%{"unsigned" => %{"redacted_because" => %{}}})
        end

      :put, _, _ ->
        ok(%{"event_id" => "$redaction"})
    end)

    assert {:ok,
            %ProviderReceipt{local_redaction_observed: true, remote_deletion_confirmed: false}} =
             Matrix.perform(%{
               request(:redact)
               | event_id: "$owned-event",
                 effect_mode: :first_attempt
             })
  end

  test "expired total deadlines and wrong bridge identities issue no mutation" do
    handler(fn _, _, _ -> ok(%{"user_id" => "@wrong:example.org"}) end)

    assert {:error, :federation_deadline} =
             Matrix.perform(%{request(:send) | deadline: System.monotonic_time(:millisecond) - 1})

    refute_received {:matrix_request, _, _, _, _}
    assert {:error, :matrix_bridge_principal_mismatch} = Matrix.perform(request(:send))
    refute_received {:matrix_request, :put, _, _, _}
  end

  test "changing the retained provider origin or server name refuses before any HTTP call" do
    handler(fn _, _, _ -> raise "provider binding refusal must not call transport" end)

    assert {:error, :federation_provider_identity_changed} =
             Matrix.perform(%{request(:send) | homeserver_origin: "https://other.example.org"})

    assert {:error, :federation_provider_identity_changed} =
             Matrix.perform(%{request(:send) | server_name: "other.example.org"})

    refute_received {:matrix_request, _, _, _, _}
  end

  test "unsafe server ACL or permission changes are refused before mutation" do
    for unsafe <- [
          Enum.reject(state(), &(&1["type"] == "m.room.server_acl")),
          Enum.reject(state(), &(&1["type"] == "m.room.power_levels")),
          Enum.map(state(), fn event ->
            if event["type"] == "m.room.power_levels" do
              put_in(event, ["content", "users"], %{
                "@bridge:example.org" => 100,
                "@foreign:example.org" => 100
              })
            else
              event
            end
          end)
        ] do
      handler(fn :get, path, _ ->
        if String.ends_with?(path, "/account/whoami"),
          do: ok(%{"user_id" => "@bridge:example.org"}),
          else: ok(unsafe)
      end)

      assert {:error, :encrypted_or_unsafe_matrix_room} = Matrix.perform(request(:send))
      refute_received {:matrix_request, :put, _, _, _}
    end
  end

  test "lost removal acknowledgement is recovered only from actual leave state and joined absence" do
    handler(fn
      :post, _, _ ->
        {:error, :outbound_timeout}

      :get, path, _ ->
        cond do
          String.ends_with?(path, "/account/whoami") ->
            ok(%{"user_id" => "@bridge:example.org"})

          String.ends_with?(path, "/state") ->
            ok(state())

          String.contains?(path, "/state/m.room.member/") ->
            ok(%{"membership" => "leave"})

          String.ends_with?(path, "/joined_members") ->
            ok(%{"joined" => %{"@bridge:example.org" => %{}}})
        end
    end)

    assert {:ok, %ProviderReceipt{local_absence_observed: true, remote_deletion_confirmed: false}} =
             Matrix.perform(%{request(:leave) | principal: "@person:remote.example.org"})

    handler(fn
      :post, _, _ ->
        {:error, :outbound_timeout}

      :get, path, _ ->
        cond do
          String.ends_with?(path, "/account/whoami") -> ok(%{"user_id" => "@bridge:example.org"})
          String.ends_with?(path, "/state") -> ok(state())
          true -> ok(%{"membership" => "invite"})
        end
    end)

    assert {:error, :federation_member_absence_unconfirmed} =
             Matrix.perform(%{request(:leave) | principal: "@person:remote.example.org"})
  end

  test "lost redaction ACK observes immediately and all later attempts are read-only" do
    Process.put(:redaction_observed, false)

    handler(fn
      :get, path, _ ->
        cond do
          String.ends_with?(path, "/account/whoami") -> ok(%{"user_id" => "@bridge:example.org"})
          String.ends_with?(path, "/state") -> ok(state())
          Process.get(:redaction_observed) -> ok(%{"unsigned" => %{"redacted_because" => %{}}})
          true -> ok(%{"unsigned" => %{}})
        end

      :put, _, _ ->
        send(self(), :redaction_put)
        {:error, :outbound_timeout}
    end)

    first = %{request(:redact) | event_id: "$owned-event", effect_mode: :first_attempt}
    assert {:error, :federation_redaction_unconfirmed} = Matrix.perform(first)
    assert_received :redaction_put

    assert_received {:matrix_request, :get,
                     "/_matrix/client/v3/rooms/%21synthetic%3Aexample.org/event/%24owned-event",
                     _, _}

    assert {:error, :federation_redaction_unconfirmed} =
             Matrix.perform(%{first | effect_mode: :recovery_only})

    refute_received :redaction_put
    Process.put(:redaction_observed, true)

    assert {:ok,
            %ProviderReceipt{local_redaction_observed: true, remote_deletion_confirmed: false}} =
             Matrix.perform(%{first | effect_mode: :recovery_only})

    refute_received :redaction_put
  end

  test "cleanup rejects changed or missing original control identity before all native HTTP" do
    handler(fn _, _, _ -> raise "retained control refusal must not call transport" end)

    for operation <- [:redact, :leave, :close], principal <- [nil, "@old-bridge:example.org"] do
      assert {:error, :federation_provider_identity_changed} =
               Matrix.perform(%{request(operation) | bridge_user: principal})
    end

    config = Application.fetch_env!(:comms_integrations, :federation_matrix)

    Application.put_env(:comms_integrations, :federation_matrix, %{
      config
      | bridge_user: "@replacement:example.org"
    })

    for operation <- [:redact, :leave, :close] do
      assert {:error, :federation_provider_identity_changed} = Matrix.perform(request(operation))
    end

    refute_received {:matrix_request, _, _, _, _}
  end

  test "cleanup refuses foreign creation, lineage or control power before a mutation" do
    states = [
      Enum.map(state(), fn event ->
        if event["type"] == "m.room.create",
          do: Map.put(event, "sender", "@foreign:example.org"),
          else: event
      end),
      Enum.map(state(), fn event ->
        if event["type"] == "org.kcomms.bridge",
          do: Map.put(event, "content", %{"lineage" => "foreign"}),
          else: event
      end),
      Enum.map(state(), fn event ->
        if event["type"] == "org.kcomms.bridge",
          do: Map.put(event, "sender", "@foreign:example.org"),
          else: event
      end),
      Enum.reject(state(), &(&1["type"] == "m.room.power_levels")),
      Enum.map(state(), fn event ->
        if event["type"] == "m.room.power_levels" do
          put_in(event, ["content", "users"], %{
            "@bridge:example.org" => 100,
            "@foreign:example.org" => 100
          })
        else
          event
        end
      end)
    ]

    for unsafe <- states, operation <- [:redact, :leave, :close] do
      handler(fn :get, path, _ ->
        if String.ends_with?(path, "/account/whoami"),
          do: ok(%{"user_id" => "@bridge:example.org"}),
          else: ok(unsafe)
      end)

      assert {:error, :unowned_matrix_cleanup_room} =
               Matrix.perform(%{request(operation) | effect_mode: :first_attempt})
    end

    refute_received {:matrix_request, :put, _, _, _}
    refute_received {:matrix_request, :post, _, _, _}
  end

  test "original-owner encrypted cleanup only observes metadata and never captures a timeline" do
    handler(fn
      :get, path, _ ->
        cond do
          String.ends_with?(path, "/account/whoami") ->
            ok(%{"user_id" => "@bridge:example.org"})

          String.ends_with?(path, "/state") ->
            ok(
              state() ++
                [
                  %{
                    "type" => "m.room.encryption",
                    "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}
                  }
                ]
            )

          String.contains?(path, "/event/") ->
            ok(%{"unsigned" => %{"redacted_because" => %{}}})

          true ->
            raise "cleanup must not request plaintext timeline"
        end
    end)

    assert {:ok,
            %ProviderReceipt{local_redaction_observed: true, remote_deletion_confirmed: false}} =
             Matrix.perform(%{
               request(:redact)
               | event_id: "$owned-event",
                 effect_mode: :recovery_only
             })

    refute_received {:matrix_request, :put, _, _, _}
    refute_received {:matrix_request, :post, _, _, _}
  end

  test "encrypted timeline events are refused without returning their content" do
    handler(fn :get, path, _ ->
      cond do
        String.ends_with?(path, "/account/whoami") ->
          ok(%{"user_id" => "@bridge:example.org"})

        String.ends_with?(path, "/state") ->
          ok(state())

        String.ends_with?(path, "/joined_members") ->
          ok(%{"joined" => %{"@bridge:example.org" => %{}}})

        String.ends_with?(path, "/messages") ->
          ok(%{
            "chunk" => [
              %{"type" => "m.room.encrypted", "content" => %{"ciphertext" => "synthetic-secret"}}
            ]
          })
      end
    end)

    assert {:error, :encrypted_matrix_event_refused} = Matrix.perform(request(:timeline))
  end

  test "uncertain send recovery is bounded read-only and never resends a withdrawn body" do
    Process.put(:history_pages, 0)

    handler(fn :get, path, _ ->
      if String.ends_with?(path, "/account/whoami") do
        ok(%{"user_id" => "@bridge:example.org"})
      else
        Process.put(:history_pages, Process.get(:history_pages) + 1)
        ok(%{"chunk" => [], "end" => "synthetic-next-page"})
      end
    end)

    assert {:error, :federation_send_outcome_unconfirmed} =
             Matrix.perform(%{
               request(:recover_event)
               | source_transaction_id: "withdrawn-original",
                 body: nil
             })

    assert Process.get(:history_pages) == 3
    refute_received {:matrix_request, :put, _, _, _}
    refute_received {:matrix_request, :post, _, _, _}
  end

  test "a safe noncanonical state decoy cannot override unsafe canonical room control" do
    for type <- ["m.room.create", "org.kcomms.bridge", "m.room.power_levels"] do
      original = Enum.find(state(), &(&1["type"] == type))

      unsafe =
        case type do
          "m.room.power_levels" ->
            put_in(original, ["content", "users"], %{"@foreign:example.org" => 100})

          _ ->
            Map.put(original, "sender", "@foreign:example.org")
        end

      decoy = Map.put(original, "state_key", "decoy")
      changed = Enum.reject(state(), &(&1["type"] == type)) ++ [unsafe, decoy]

      handler(fn :get, path, _ ->
        if String.ends_with?(path, "/account/whoami"),
          do: ok(%{"user_id" => "@bridge:example.org"}),
          else: ok(changed)
      end)

      assert {:error, :unowned_matrix_cleanup_room} =
               Matrix.perform(%{request(:redact) | effect_mode: :first_attempt})
    end

    refute_received {:matrix_request, :put, _, _, _}
  end

  test "active-room security requires one canonical state event and refuses safe decoys" do
    for type <- [
          "m.room.create",
          "org.kcomms.bridge",
          "m.room.join_rules",
          "m.room.guest_access",
          "m.room.server_acl",
          "m.room.power_levels"
        ] do
      original = Enum.find(state(), &(&1["type"] == type))

      for events <- [
            Enum.reject(state(), &(&1["type"] == type)) ++
              [Map.put(original, "state_key", "decoy")],
            state() ++ [original]
          ] do
        handler(fn :get, path, _ ->
          if String.ends_with?(path, "/account/whoami"),
            do: ok(%{"user_id" => "@bridge:example.org"}),
            else: ok(events)
        end)

        assert {:error, :encrypted_or_unsafe_matrix_room} = Matrix.perform(request(:send))
      end
    end

    refute_received {:matrix_request, :put, _, _, _}
  end

  defp request(op),
    do: %ProviderRequest{
      operation: op,
      transaction_id: "synthetic-stable-transaction",
      deadline: System.monotonic_time(:millisecond) + 2000,
      room_id: "!synthetic:example.org",
      homeserver_origin: "https://matrix.example.org",
      server_name: "example.org",
      bridge_user: "@bridge:example.org",
      alias_localpart: "kc_fed_synthetic",
      allowed_servers: ["remote.example.org"],
      body: "synthetic text"
    }

  defp handler(fun), do: Process.put(:matrix_handler, fun)
  defp ok(body), do: {:ok, %{status: 200, body: Jason.encode!(body)}}

  defp state,
    do: [
      %{"type" => "m.room.create", "state_key" => "", "sender" => "@bridge:example.org"},
      %{
        "type" => "m.room.server_acl",
        "state_key" => "",
        "content" => %{
          "allow" => ["example.org", "remote.example.org"],
          "deny" => [],
          "allow_ip_literals" => false
        }
      },
      %{
        "type" => "m.room.power_levels",
        "state_key" => "",
        "content" => %{
          "users" => %{"@bridge:example.org" => 100},
          "users_default" => 0,
          "state_default" => 100,
          "invite" => 100,
          "kick" => 100,
          "ban" => 100,
          "redact" => 100,
          "events" => %{"m.room.encryption" => 100}
        }
      },
      %{
        "type" => "m.room.join_rules",
        "state_key" => "",
        "content" => %{"join_rule" => "invite"}
      },
      %{
        "type" => "m.room.guest_access",
        "state_key" => "",
        "content" => %{"guest_access" => "forbidden"}
      },
      %{
        "type" => "org.kcomms.bridge",
        "state_key" => "",
        "sender" => "@bridge:example.org",
        "content" => %{"lineage" => "kc_fed_synthetic"}
      }
    ]
end
