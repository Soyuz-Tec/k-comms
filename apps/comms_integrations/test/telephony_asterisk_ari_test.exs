defmodule CommsIntegrations.Telephony.AsteriskARITest do
  use ExUnit.Case, async: false
  alias CommsIntegrations.Telephony.AsteriskARI
  alias CommsCore.Telephony.ControlRequest
  @call_id "4acf5490-60ba-439d-8a74-84960a9a1e4d"

  setup do
    values = %{
      telephony_pbx_enabled: true,
      telephony_pbx_qualified: true,
      telephony_pbx_api_url: "https://pbx.example.test",
      telephony_pbx_username: "k-comms",
      telephony_pbx_password: "synthetic-provider-secret-long-enough",
      telephony_pbx_endpoint: "qualified-carrier",
      telephony_pbx_application: "k-comms",
      telephony_pbx_destination_prefixes: ["+1415"],
      telephony_pbx_webhook_secret: String.duplicate("s", 32)
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_integrations, key, value)
        {key, :error} -> Application.delete_env(:comms_integrations, key)
      end)
    end)

    {:ok, state} =
      start_supervised(
        {Agent,
         fn ->
           %{
             channels: %{
               "external" => channel("external", "external"),
               "app" => channel("app", "app")
             },
             bridges: %{
               "original" => %{
                 "id" => "original",
                 "bridge_type" => "mixing",
                 "channels" => ["external", "app"]
               }
             },
             requests: []
           }
         end}
      )

    %{state: state, requester: requester(state)}
  end

  test "hold actually moves only the external channel to a holding bridge with MOH; resume restores mixing",
       %{state: state, requester: requester} do
    assert {:ok, %{control_state: "held", pbx_state: bindings}} =
             AsteriskARI.execute_control(command(:hold), requester)

    held = Agent.get(state, & &1)
    assert held.bridges[bindings["holding"]]["channels"] == ["external"]
    assert held.bridges["original"]["channels"] == ["app"]

    assert Enum.any?(held.requests, fn {method, path, _} ->
             method == :post and String.ends_with?(path, "/moh")
           end)

    assert {:ok, %{control_state: "connected"}} =
             AsteriskARI.execute_control(%{command(:resume) | pbx_state: bindings}, requester)

    resumed = Agent.get(state, & &1)
    assert Enum.sort(resumed.bridges["original"]["channels"]) == ["app", "external"]
  end

  test "tenant/room/call mismatch and ambiguous legs fail before every provider mutation", %{
    state: state,
    requester: requester
  } do
    Agent.update(state, fn s ->
      put_in(s, [:channels, "external", "channelvars", "KC_TENANT_ID"], "foreign-tenant")
    end)

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.execute_control(command(:hold), requester)

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)

    Agent.update(state, fn s ->
      %{
        s
        | channels:
            Map.put(s.channels, "external", channel("external", "external"))
            |> Map.put("duplicate", channel("duplicate", "external")),
          requests: []
      }
    end)

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.execute_control(command(:hold), requester)

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "consultation creates one allowlisted channel and recovery cannot redial a missing uncertain leg",
       %{state: state, requester: requester} do
    # The worker persists these exact bindings before the first provider effect.
    original = %{
      command(:consult_transfer)
      | destination: "+14155550123",
        pbx_state: persisted_bindings()
    }

    assert {:error, :telephony_consultation_pending} =
             AsteriskARI.execute_control(original, requester)

    consult_id = "kc_consult_" <> String.replace(@call_id, "-", "")
    assert Agent.get(state, & &1.channels[consult_id])
    Agent.update(state, fn s -> put_in(s, [:channels, consult_id, "state"], "Up") end)

    assert {:ok, %{control_state: "consulting"}} =
             AsteriskARI.execute_control(%{original | reconcile: true}, requester)

    originates =
      Agent.get(
        state,
        &Enum.count(&1.requests, fn {method, path, _} ->
          method == :post and path == "/channels"
        end)
      )

    assert originates == 1

    Agent.update(state, fn s ->
      %{
        s
        | channels: Map.delete(s.channels, consult_id),
          bridges:
            Map.new(s.bridges, fn {id, bridge} ->
              {id, Map.update!(bridge, "channels", &List.delete(&1, consult_id))}
            end)
      }
    end)

    assert {:error, :telephony_outcome_unknown} =
             AsteriskARI.execute_control(%{original | reconcile: true}, requester)

    assert Agent.get(
             state,
             &Enum.count(&1.requests, fn {method, path, _} ->
               method == :post and path == "/channels"
             end)
           ) == 1

    assert {:ok, %{control_state: "connected"}} =
             AsteriskARI.execute_control(%{original | action: :cancel_transfer}, requester)

    assert Enum.sort(Agent.get(state, & &1.bridges["original"]["channels"])) == [
             "app",
             "external"
           ]

    assert Agent.get(
             state,
             &Enum.count(&1.requests, fn {method, path, _} ->
               method == :post and path == "/channels"
             end)
           ) == 1
  end

  test "persisted mixing bridge cannot admit a substituted foreign channel", %{
    state: state,
    requester: requester
  } do
    bindings = persisted_bindings()

    foreign =
      put_in(channel("foreign", "consult"), ["channelvars", "KC_TENANT_ID"], "foreign-tenant")

    Agent.update(state, fn s ->
      %{
        s
        | channels: Map.put(s.channels, "foreign", foreign),
          bridges: put_in(s.bridges, ["original", "channels"], ["app", "foreign"]),
          requests: []
      }
    end)

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.execute_control(%{command(:resume) | pbx_state: bindings}, requester)

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "a pre-existing holding bridge with foreign members rejects before mutation", %{
    state: state,
    requester: requester
  } do
    holding = persisted_bindings()["holding"]

    Agent.update(state, fn s ->
      %{
        s
        | bridges:
            Map.put(s.bridges, holding, %{
              "id" => holding,
              "bridge_type" => "holding",
              "channels" => ["foreign"]
            })
      }
    end)

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.execute_control(command(:hold), requester)

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "uncertain consultation cancel cannot hang up a substituted foreign leg", %{
    state: state,
    requester: requester
  } do
    binding = persisted_bindings()

    foreign =
      put_in(
        channel(binding["consult"], "consult"),
        ["channelvars", "KC_TENANT_ID"],
        "foreign-tenant"
      )

    Agent.update(state, fn s ->
      %{s | channels: Map.put(s.channels, binding["consult"], foreign)}
    end)

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.execute_control(
               %{command(:cancel_transfer) | pbx_state: binding},
               requester
             )

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "disabled/unqualified providers and unsafe destinations never produce control side effects",
       %{state: state, requester: requester} do
    Application.put_env(:comms_integrations, :telephony_pbx_qualified, false)

    assert {:error, :telephony_control_unsupported} =
             AsteriskARI.execute_control(command(:hold), requester)

    assert Agent.get(state, & &1.requests) == []
    Application.put_env(:comms_integrations, :telephony_pbx_qualified, true)

    assert {:error, :telephony_destination_forbidden} =
             AsteriskARI.execute_control(
               %{command(:consult_transfer) | destination: "+442071234567"},
               requester
             )

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
    Application.put_env(:comms_integrations, :telephony_pbx_api_url, "https://127.0.0.1")
    assert {:error, :telephony_provider_unavailable} = AsteriskARI.configuration()
  end

  test "consent notice signatures bind raw body, timestamp and actual PlaybackFinished event" do
    body =
      Jason.encode!(%{
        type: "PlaybackFinished",
        event_id: "notice-event",
        playback: %{
          id: "kc_notice_" <> String.replace(@call_id, "-", ""),
          state: "done",
          target_uri: "channel:external",
          media_uri: "sound:custom/consent"
        }
      })

    timestamp = Integer.to_string(System.system_time(:second))

    signature =
      :crypto.mac(:hmac, :sha256, String.duplicate("s", 32), timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    assert {:ok, %{call_id: @call_id, channel_id: "external"}} =
             AsteriskARI.verify_event(body, "v1:" <> timestamp <> ":" <> signature)

    assert {:error, :invalid_provider_webhook} =
             AsteriskARI.verify_event(body <> " ", "v1:" <> timestamp <> ":" <> signature)

    assert {:error, :invalid_provider_webhook} =
             AsteriskARI.verify_event(body, "v1:0:" <> signature)

    assert {:error, :invalid_provider_webhook} =
             AsteriskARI.verify_event(
               body,
               "v1:" <> timestamp <> ":" <> String.duplicate("0", 64)
             )
  end

  test "terminal cleanup removes bound paid legs and private bridges with admissions disabled; unrelated calls and stored voicemail remain",
       %{state: state, requester: requester} do
    bindings = persisted_bindings()

    foreign =
      put_in(channel("unrelated", "external"), ["channelvars", "KC_CALL_ID"], "another-call")

    Agent.update(state, fn s ->
      %{
        s
        | channels:
            s.channels
            |> Map.put(bindings["consult"], channel(bindings["consult"], "consult"))
            |> Map.put("unrelated", foreign),
          bridges: %{
            "original" => %{
              "id" => "original",
              "bridge_type" => "mixing",
              "channels" => ["app", bindings["consult"]]
            },
            bindings["holding"] => %{
              "id" => bindings["holding"],
              "bridge_type" => "holding",
              "channels" => ["external"]
            },
            "other" => %{"id" => "other", "bridge_type" => "mixing", "channels" => ["unrelated"]}
          }
      }
    end)

    Application.put_env(:comms_integrations, :telephony_pbx_enabled, false)
    Application.put_env(:comms_integrations, :telephony_pbx_qualified, false)
    assert :ok = AsteriskARI.cleanup_call(provider_command(bindings), requester)
    cleaned = Agent.get(state, & &1)
    assert Map.keys(cleaned.channels) == ["unrelated"]
    assert Map.keys(cleaned.bridges) == ["other"]

    refute Enum.any?(cleaned.requests, fn {method, path, _} ->
             method == :post or String.starts_with?(path, "/recordings/")
           end)

    assert :ok = AsteriskARI.cleanup_call(provider_command(bindings), requester)
  end

  test "cleanup retains and removes an exact empty IVR destination bridge after an uncertain connection",
       %{state: state, requester: requester} do
    bridge_id = "kc_ivr_mix_" <> String.replace(@call_id, "-", "")
    bindings = Map.put(persisted_bindings(), "destination_bridge", bridge_id)

    Agent.update(state, fn s ->
      %{
        s
        | bridges:
            Map.put(s.bridges, bridge_id, %{
              "id" => bridge_id,
              "bridge_type" => "mixing",
              "channels" => []
            })
      }
    end)

    assert :ok = AsteriskARI.cleanup_call(provider_command(bindings), requester)
    assert Agent.get(state, & &1.bridges) == %{}

    assert Enum.any?(Agent.get(state, & &1.requests), fn {method, path, _} ->
             method == :delete and path == "/bridges/" <> bridge_id
           end)
  end

  test "system voicemail preserves frozen IVR bindings instead of substituting its holding bridge",
       %{requester: requester} do
    bindings =
      Map.put(
        persisted_bindings(),
        "destination_bridge",
        "kc_ivr_mix_" <> String.replace(@call_id, "-", "")
      )

    request = %{command(:voicemail) | system: true, pbx_state: bindings}
    assert {:ok, ^bindings} = AsteriskARI.prepare_control(request, requester)
  end

  test "a substituted IVR destination bridge binding cannot confer cleanup authority",
       %{state: state, requester: requester} do
    bindings = Map.put(persisted_bindings(), "destination_bridge", "other-call-bridge")

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.cleanup_call(provider_command(bindings), requester)

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "cleanup preflight rejects a substituted consult channel before deleting any original leg",
       %{state: state, requester: requester} do
    bindings = persisted_bindings()

    foreign =
      put_in(
        channel(bindings["consult"], "consult"),
        ["channelvars", "KC_TENANT_ID"],
        "foreign-tenant"
      )

    Agent.update(state, &%{&1 | channels: Map.put(&1.channels, bindings["consult"], foreign)})

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.cleanup_call(provider_command(bindings), requester)

    assert map_size(Agent.get(state, & &1.channels)) == 3
    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "cleanup cannot destroy a saved bridge containing a foreign member", %{
    state: state,
    requester: requester
  } do
    foreign = put_in(channel("foreign", "app"), ["channelvars", "KC_CALL_ID"], "other-call")

    Agent.update(state, fn s ->
      %{
        s
        | channels: Map.put(s.channels, "foreign", foreign),
          bridges: put_in(s.bridges, ["original", "channels"], ["app", "external", "foreign"])
      }
    end)

    assert {:error, :telephony_pbx_binding_invalid} =
             AsteriskARI.cleanup_call(provider_command(persisted_bindings()), requester)

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "a partial provider outage cannot acknowledge cleanup; retry deletes only remaining exact resources",
       %{state: state, requester: requester} do
    bindings = persisted_bindings()

    Agent.update(
      state,
      &%{
        &1
        | channels:
            Map.put(&1.channels, bindings["consult"], channel(bindings["consult"], "consult"))
      }
    )

    broken = fn method, url, headers, body, opts ->
      if method == :delete and
           String.ends_with?(URI.parse(url).path, "/channels/" <> bindings["consult"]),
         do: {:ok, %{status: 503, body: "{}"}},
         else: requester.(method, url, headers, body, opts)
    end

    assert {:error, :telephony_outcome_unknown} =
             AsteriskARI.cleanup_call(provider_command(bindings), broken)

    assert Agent.get(state, & &1.channels[bindings["consult"]])
    assert :ok = AsteriskARI.cleanup_call(provider_command(bindings), requester)
    assert Agent.get(state, & &1.channels) == %{}
    assert Agent.get(state, & &1.bridges) == %{}
    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method == :post end)
  end

  test "successful delete acknowledgements require final provider absence proof", %{
    state: state,
    requester: requester
  } do
    dishonest_ack = fn method, url, headers, body, opts ->
      if method == :delete and String.ends_with?(URI.parse(url).path, "/bridges/original"),
        do: ok(%{}),
        else: requester.(method, url, headers, body, opts)
    end

    assert {:error, :telephony_provider_unavailable} =
             AsteriskARI.cleanup_call(provider_command(persisted_bindings()), dishonest_ack)

    assert Agent.get(state, & &1.bridges["original"])
    assert :ok = AsteriskARI.cleanup_call(provider_command(persisted_bindings()), requester)
  end

  test "queue cleanup discovers the deterministic holding bridge before a control binding exists",
       %{state: state, requester: requester} do
    holding = persisted_bindings()["holding"]

    Agent.update(state, fn s ->
      %{
        s
        | channels: Map.take(s.channels, ["external"]),
          bridges: %{
            holding => %{"id" => holding, "bridge_type" => "holding", "channels" => ["external"]}
          }
      }
    end)

    assert :ok = AsteriskARI.cleanup_call(provider_command(%{}), requester)
    assert Agent.get(state, & &1.channels) == %{}
    assert Agent.get(state, & &1.bridges) == %{}
  end

  test "handoff monitoring preserves the live exact pair and detects original external remote end without dialing",
       %{state: state, requester: requester} do
    bindings = persisted_bindings()

    Agent.update(state, fn s ->
      %{
        s
        | channels:
            s.channels
            |> Map.delete("app")
            |> Map.put(bindings["consult"], channel(bindings["consult"], "consult")),
          bridges: put_in(s.bridges, ["original", "channels"], ["external", bindings["consult"]])
      }
    end)

    assert {:ok, :active} = AsteriskARI.bound_call_status(provider_command(bindings), requester)

    Agent.update(state, fn s ->
      %{
        s
        | channels: Map.delete(s.channels, "external"),
          bridges: put_in(s.bridges, ["original", "channels"], [bindings["consult"]])
      }
    end)

    assert {:ok, :ended} = AsteriskARI.bound_call_status(provider_command(bindings), requester)
    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
    assert :ok = AsteriskARI.cleanup_call(provider_command(bindings), requester)
    assert Agent.get(state, & &1.channels) == %{}
  end

  test "completed target remote hangup ends the bound transferred pair; uncertain pre-handoff caller is preserved",
       %{state: state, requester: requester} do
    bindings = persisted_bindings()
    assert {:ok, :ended} = AsteriskARI.bound_call_status(provider_command(bindings), requester)

    assert {:ok, :active} =
             AsteriskARI.bound_call_status(
               %{provider_command(bindings) | control_state: "consulting"},
               requester
             )

    Agent.update(state, fn s ->
      %{
        s
        | channels: Map.delete(s.channels, "app"),
          bridges: put_in(s.bridges, ["original", "channels"], ["external"])
      }
    end)

    assert {:ok, :ended} =
             AsteriskARI.bound_call_status(
               %{provider_command(bindings) | control_state: "consulting"},
               requester
             )

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, _, _} -> method != :get end)
  end

  test "caller-only capture remains active without app or consult and stops only on original bound caller absence",
       %{state: state, requester: requester} do
    bindings = persisted_bindings()

    Agent.update(state, fn s ->
      %{
        s
        | channels: Map.take(s.channels, ["external"]),
          bridges: put_in(s.bridges, ["original", "channels"], [])
      }
    end)

    capture = %{provider_command(bindings) | control_state: "voicemail"}
    assert {:ok, :active} = AsteriskARI.bound_call_status(capture, requester)
    Agent.update(state, &%{&1 | channels: %{}})
    assert {:ok, :ended} = AsteriskARI.bound_call_status(capture, requester)

    refute Enum.any?(Agent.get(state, & &1.requests), fn {method, path, _} ->
             method != :get or String.starts_with?(path, "/recordings/")
           end)
  end

  defp provider_command(bindings) do
    %CommsCore.Telephony.ProviderCommand{
      call_id: @call_id,
      tenant_id: "tenant-exact",
      route_id: nil,
      provider_room: "kc_tel_exact",
      provider_identity: "sip-exact",
      direction: :outbound,
      status: :ended,
      from_number: "+14155550100",
      to_number: "+14155550101",
      inbound_trunk_id: "ST_in",
      outbound_trunk_id: "ST_out",
      pbx_state: bindings,
      control_state: "transferred",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }
  end

  defp persisted_bindings do
    suffix = String.replace(@call_id, "-", "")

    %{
      "external" => "external",
      "app" => "app",
      "mixing" => "original",
      "holding" => "kc_hold_" <> suffix,
      "consult" => "kc_consult_" <> suffix,
      "recording" => "kc_vm_" <> suffix
    }
  end

  defp command(action),
    do: %ControlRequest{
      command_id: Ecto.UUID.generate(),
      call_id: @call_id,
      tenant_id: "tenant-exact",
      action: action,
      provider_room: "kc_tel_exact",
      provider_identity: "sip-exact",
      destination: nil,
      pbx_state: %{},
      reconcile: false
    }

  defp channel(id, role),
    do: %{
      "id" => id,
      "state" => "Up",
      "channelvars" => %{
        "KC_TENANT_ID" => "tenant-exact",
        "KC_CALL_ID" => @call_id,
        "KC_LIVEKIT_ROOM" => "kc_tel_exact",
        "KC_SIP_IDENTITY" => "sip-exact",
        "KC_ROLE" => role
      }
    }

  defp requester(state) do
    fn method, url, _headers, body, opts ->
      assert opts[:allowed_hosts] == ["pbx.example.test"]
      assert opts[:allowed_ports] == [443]
      uri = URI.parse(url)
      path = String.replace_prefix(uri.path, "/ari", "")
      query = URI.decode_query(uri.query || "")

      Agent.get_and_update(state, fn s ->
        s = %{s | requests: s.requests ++ [{method, path, query}]}

        cond do
          method == :get and path == "/channels" ->
            {ok(Map.values(s.channels)), s}

          method == :get and path == "/bridges" ->
            {ok(Map.values(s.bridges)), s}

          method == :get and String.starts_with?(path, "/channels/") ->
            id = String.replace_prefix(path, "/channels/", "")
            {found(s.channels[id]), s}

          method == :get and String.starts_with?(path, "/bridges/") ->
            id = String.replace_prefix(path, "/bridges/", "")
            {found(s.bridges[id]), s}

          method == :post and path == "/channels" ->
            variables = Jason.decode!(body)["variables"]
            ch = %{"id" => query["channelId"], "state" => "Down", "channelvars" => variables}
            {ok(ch), %{s | channels: Map.put(s.channels, ch["id"], ch)}}

          method == :post and String.ends_with?(path, "/removeChannel") ->
            id =
              path
              |> String.replace_prefix("/bridges/", "")
              |> String.replace_suffix("/removeChannel", "")

            {ok(%{}),
             update_in(s, [:bridges, id, "channels"], &List.delete(&1, query["channel"]))}

          method == :post and String.ends_with?(path, "/addChannel") ->
            id =
              path
              |> String.replace_prefix("/bridges/", "")
              |> String.replace_suffix("/addChannel", "")

            {ok(%{}),
             update_in(s, [:bridges, id, "channels"], &Enum.uniq([query["channel"] | &1]))}

          method == :post and String.starts_with?(path, "/bridges/") and
              not String.ends_with?(path, "/moh") ->
            id = String.replace_prefix(path, "/bridges/", "")
            bridge = %{"id" => id, "bridge_type" => query["type"], "channels" => []}
            {ok(bridge), %{s | bridges: Map.put(s.bridges, id, bridge)}}

          method == :delete and String.starts_with?(path, "/channels/") ->
            id = String.replace_prefix(path, "/channels/", "")

            {ok(%{}),
             %{
               s
               | channels: Map.delete(s.channels, id),
                 bridges:
                   Map.new(s.bridges, fn {bridge_id, bridge} ->
                     {bridge_id, Map.update!(bridge, "channels", &List.delete(&1, id))}
                   end)
             }}

          method == :delete and String.starts_with?(path, "/bridges/") ->
            id = String.replace_prefix(path, "/bridges/", "")
            {ok(%{}), %{s | bridges: Map.delete(s.bridges, id)}}

          String.ends_with?(path, "/moh") ->
            {ok(%{}), s}

          true ->
            {{:ok, %{status: 404, body: "{}"}}, s}
        end
      end)
    end
  end

  defp ok(value), do: {:ok, %{status: 200, body: Jason.encode!(value)}}
  defp found(nil), do: {:ok, %{status: 404, body: "{}"}}
  defp found(value), do: ok(value)
end
