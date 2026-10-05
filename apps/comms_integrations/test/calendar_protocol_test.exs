defmodule CommsIntegrations.CalendarProtocolTest do
  use ExUnit.Case, async: false
  alias CommsCore.AudioCalls.CalendarSync.{EventCommand, ExternalIdentityReceipt, OAuthRequest}
  alias CommsIntegrations.Calendar.{Config, Events, Http, OAuth}

  defmodule FixtureTransport do
    def request(destination, method, headers, body, opts) do
      send(self(), {:calendar_protocol, destination.uri, method, headers, body, opts})
      [next | rest] = Process.get(:calendar_fixture_responses, [])
      Process.put(:calendar_fixture_responses, rest)

      case next do
        {:sleep, duration, response} ->
          Process.sleep(duration)
          response

        response ->
          response
      end
    end
  end

  setup do
    previous = Application.get_env(:comms_integrations, :calendar_providers)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:comms_integrations, :calendar_providers),
        else: Application.put_env(:comms_integrations, :calendar_providers, previous)
    end)

    common = %{
      enabled: true,
      client_id: "synthetic-calendar-client",
      client_secret: "synthetic-calendar-client-secret",
      workspace_origin: "https://workspace.example.test"
    }

    providers = %{
      google:
        Map.put(
          common,
          :redirect_uri,
          "https://workspace.example.test/api/v1/calendar/oauth/google/callback"
        ),
      microsoft:
        Map.merge(common, %{
          tenant_id: "635683af-0c58-4d66-8eb5-73f66b66cfdf",
          redirect_uri: "https://workspace.example.test/api/v1/calendar/oauth/microsoft/callback"
        })
    }

    Application.put_env(:comms_integrations, :calendar_providers, providers)

    {:ok,
     providers: providers,
     opts: [transport: FixtureTransport, resolver: fn _ -> [{93, 184, 216, 34}] end]}
  end

  test "authorization uses fixed minimal delegated scopes, exact callback and S256", %{
    providers: providers
  } do
    verifier = String.duplicate("v", 64)

    for provider <- [:google, :microsoft] do
      assert {:ok, url} =
               OAuth.authorization_url(
                 provider,
                 String.duplicate("s", 43),
                 String.duplicate("n", 43),
                 verifier
               )

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      assert query["scope"] == Enum.join(Config.scopes(provider), " ")

      assert query["code_challenge"] ==
               Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

      assert query["code_challenge_method"] == "S256"
      assert query["redirect_uri"] == providers[provider].redirect_uri
      assert query["prompt"] == "consent"
      refute String.contains?(url, "client_secret")
      refute String.contains?(query["scope"], "User.Read")
    end
  end

  test "disabled, common-tenant and foreign-origin configuration remains unavailable", %{
    providers: providers
  } do
    Application.put_env(:comms_integrations, :calendar_providers, %{})
    assert {:error, :calendar_provider_not_configured} = Config.load(:google)

    Application.put_env(:comms_integrations, :calendar_providers, %{
      microsoft: %{providers.microsoft | tenant_id: "common"}
    })

    assert {:error, :calendar_provider_not_configured} = Config.load(:microsoft)

    Application.put_env(:comms_integrations, :calendar_providers, %{
      google: %{
        providers.google
        | redirect_uri: "https://attacker.example.test/api/v1/calendar/oauth/google/callback"
      }
    })

    assert {:error, :calendar_provider_not_configured} = Config.load(:google)
  end

  test "refresh does not broaden scopes and preserves rotation as an explicit owner decision", %{
    opts: opts
  } do
    fixture([
      ok(%{
        token_type: "Bearer",
        access_token: "synthetic-access",
        expires_in: 3600,
        scope: "https://www.googleapis.com/auth/calendar.events.owned"
      })
    ])

    request = %OAuthRequest{
      provider: :google,
      operation: :refresh,
      refresh_token: "synthetic-refresh",
      deadline_ms: deadline()
    }

    assert {:ok, receipt} = OAuth.token(request, opts)
    assert receipt.refresh_token == nil
    assert receipt.identity == nil

    assert_received {:calendar_protocol, %{host: "oauth2.googleapis.com", path: "/token"}, :post,
                     _, body, transport_opts}

    assert URI.decode_query(body)["refresh_token"] == "synthetic-refresh"
    assert transport_opts[:deadline_ms] <= request.deadline_ms

    fixture([
      ok(%{
        token_type: "Bearer",
        access_token: "synthetic-access",
        expires_in: 3600,
        scope: "https://www.googleapis.com/auth/calendar"
      })
    ])

    assert {:error, :calendar_provider_scope_denied} = OAuth.token(request, opts)
  end

  test "initial offline exchange cannot succeed without a usable refresh token", %{opts: opts} do
    fixture([
      ok(%{
        token_type: "Bearer",
        access_token: "synthetic-access",
        expires_in: 3600,
        scope: "openid https://www.googleapis.com/auth/calendar.events.owned"
      })
    ])

    request = %OAuthRequest{
      provider: :google,
      operation: :exchange,
      code: "synthetic-code",
      verifier: String.duplicate("v", 64),
      nonce: String.duplicate("n", 43),
      deadline_ms: deadline()
    }

    assert {:error, :invalid_calendar_provider_response} = OAuth.token(request, opts)
    assert Process.get(:calendar_fixture_responses) == []
  end

  test "invalid grant is terminal and raw provider errors do not cross the port", %{opts: opts} do
    fixture([
      response(400, %{error: "invalid_grant", error_description: "SECRET PRIVATE PROVIDER DETAIL"})
    ])

    assert {:error, :calendar_reauthorization_required} =
             OAuth.token(
               %OAuthRequest{
                 provider: :microsoft,
                 operation: :refresh,
                 refresh_token: "synthetic-refresh",
                 deadline_ms: deadline()
               },
               opts
             )
  end

  test "Google event create exports no attendees or guest token and verifies opaque ownership", %{
    opts: opts
  } do
    command = command(:google, :create)
    fixture([userinfo(command), ok(google_event(command), 201)])
    assert {:ok, %{outcome: :applied, external_id: id}} = Events.event(command, opts)
    assert id == Events.external_id(:google, command.marker_id)

    assert_received {:calendar_protocol,
                     %{host: "openidconnect.googleapis.com", path: "/v1/userinfo"}, :get, _, "",
                     _}

    assert_received {:calendar_protocol, %{host: "www.googleapis.com", query: "sendUpdates=none"},
                     :post, _, body, _}

    exported = Jason.decode!(body)
    refute Map.has_key?(exported, "attendees")
    assert exported["summary"] == "Synthetic planning"
    assert exported["extendedProperties"]["private"]["kcommsManaged"] == command.marker_id
    assert exported["start"]["dateTime"] == "2026-10-06T13:00:00Z"
    refute String.contains?(body, "synthetic-access")
  end

  test "a different account is rejected before its otherwise plausible 404", %{opts: opts} do
    command = command(:google, :get)
    fixture([ok(%{sub: "different-account"}), response(404, %{})])
    assert {:error, :calendar_external_account_binding_failed} = Events.event(command, opts)
    assert length(Process.get(:calendar_fixture_responses)) == 1

    refute_received {:calendar_protocol, %{path: "/calendar/v3/calendars/primary/events/" <> _},
                     _, _, _, _}
  end

  test "authenticated exact-account 404 and accepted delete have distinct receipts", %{opts: opts} do
    get = command(:google, :get)
    fixture([userinfo(get), response(404, %{})])
    assert {:ok, %{outcome: :absent}} = Events.event(get, opts)
    delete = %{get | operation: :delete}
    fixture([userinfo(delete), response(204, "")])
    assert {:ok, %{outcome: :removal_accepted}} = Events.event(delete, opts)
  end

  test "provider changed etag produces an explicit conflict without overwrite", %{opts: opts} do
    command = command(:google, :update)
    fixture([userinfo(command), response(412, %{private_error: "not exposed"})])
    assert {:ok, %{outcome: :conflict}} = Events.event(command, opts)
    assert_received {:calendar_protocol, _, :patch, headers, _, _}
    assert {"if-match", "\"old-etag\""} in headers
  end

  test "a lost create acknowledgement remains uncertain", %{opts: opts} do
    command = command(:google, :create)
    fixture([userinfo(command), {:error, :outbound_timeout}])
    assert {:ok, %{outcome: :uncertain}} = Events.event(command, opts)
    assert Process.get(:calendar_fixture_responses) == []
  end

  test "Microsoft create uses a persisted transaction UUID, immutable IDs and UTC", %{opts: opts} do
    command = command(:microsoft, :create)
    fixture([userinfo(command), ok(microsoft_event(command, "opaque/id+one"), 201)])
    assert {:ok, %{outcome: :applied, external_id: "opaque/id+one"}} = Events.event(command, opts)

    assert_received {:calendar_protocol,
                     %{host: "graph.microsoft.com", path: "/v1.0/me/calendar/events"}, :post,
                     headers, body, _}

    assert {"prefer", "IdType=\"ImmutableId\""} in headers
    exported = Jason.decode!(body)
    assert exported["transactionId"] == command.marker_id
    assert exported["start"] == %{"dateTime" => "2026-10-06T13:00:00", "timeZone" => "UTC"}
    refute Map.has_key?(exported, "attendees")
  end

  test "Microsoft recovery searches only its exact opaque marker and reports duplicates", %{
    opts: opts
  } do
    command = command(:microsoft, :reconcile)

    fixture([
      userinfo(command),
      ok(%{value: [microsoft_event(command, "one"), microsoft_event(command, "two")]})
    ])

    assert {:ok, %{outcome: :duplicate, verified_ids: ["one", "two"]}} =
             Events.event(command, opts)

    assert_received {:calendar_protocol,
                     %{
                       host: "graph.microsoft.com",
                       path: "/v1.0/me/calendar/events",
                       query: query
                     }, :get, _, _, _}

    decoded = URI.decode_query(query)
    assert decoded["$top"] == "2"
    assert decoded["$filter"] =~ command.marker_id
    assert decoded["$filter"] =~ Events.marker_property()
    refute decoded["$filter"] =~ "transactionId"
  end

  test "a raw or wrong-marker provider object cannot become an applied receipt", %{opts: opts} do
    command = command(:google, :create)

    fixture([
      userinfo(command),
      ok(
        %{
          id: Events.external_id(:google, command.marker_id),
          etag: "etag",
          summary: "PRIVATE EXTERNAL TITLE"
        },
        201
      )
    ])

    assert {:error, :calendar_managed_event_binding_failed} = Events.event(command, opts)
  end

  test "token-bearing and foreign-origin links are rejected before any network call", %{
    opts: opts
  } do
    for url <- [
          "https://workspace.example.test/meetings/" <> Ecto.UUID.generate() <> "?token=secret",
          "https://attacker.example.test/meetings/" <> Ecto.UUID.generate()
        ] do
      assert {:error, :invalid_calendar_event_command} =
               Events.event(%{command(:google, :create) | authenticated_url: url}, opts)
    end

    refute_received {:calendar_protocol, _, _, _, _, _}
  end

  test "Microsoft unlink never calls the broad session revocation API", %{opts: opts} do
    assert {:ok, :external_unconfirmed} =
             OAuth.revoke(:microsoft, "synthetic-refresh", deadline(), opts)

    refute_received {:calendar_protocol, _, _, _, _, _}
  end

  test "deep and oversized responses and delayed acknowledgements fail closed", %{opts: opts} do
    nested = Enum.reduce(1..14, %{}, fn _, acc -> %{"child" => acc} end)
    assert {:error, :invalid_calendar_provider_response} = Http.json(Jason.encode!(nested))

    assert {:error, :invalid_calendar_provider_response} =
             Http.json(String.duplicate("x", 262_145))

    fixture([{:sleep, 20, ok(%{sub: "synthetic-subject"})}])

    assert {:error, :calendar_provider_timeout} =
             Http.request(
               :get,
               "https://openidconnect.googleapis.com/v1/userinfo",
               [],
               "",
               System.monotonic_time(:millisecond) + 10,
               opts
             )
  end

  defp command(provider, operation) do
    marker = Ecto.UUID.generate()

    %EventCommand{
      provider: provider,
      operation: operation,
      marker_id: marker,
      access_token: "synthetic-access",
      deadline_ms: deadline(),
      identity: %ExternalIdentityReceipt{
        provider: provider,
        external_subject: "synthetic-object",
        oidc_subject: "synthetic-subject"
      },
      external_id:
        if(provider == :google,
          do: Events.external_id(:google, marker),
          else: "opaque-existing-id"
        ),
      etag: "\"old-etag\"",
      title: "Synthetic planning",
      starts_at: ~U[2026-10-06 13:00:00Z],
      ends_at: ~U[2026-10-06 13:30:00Z],
      timezone: "Europe/London",
      authenticated_url: "https://workspace.example.test/meetings/" <> Ecto.UUID.generate()
    }
  end

  defp google_event(command),
    do: %{
      id: Events.external_id(:google, command.marker_id),
      etag: "\"new-etag\"",
      extendedProperties: %{private: %{kcommsManaged: command.marker_id}}
    }

  defp microsoft_event(command, id),
    do: %{
      "id" => id,
      "@odata.etag" => "\"new-etag\"",
      "singleValueExtendedProperties" => [
        %{"id" => Events.marker_property(), "value" => command.marker_id}
      ]
    }

  defp userinfo(command), do: ok(%{sub: command.identity.oidc_subject})
  defp fixture(responses), do: Process.put(:calendar_fixture_responses, responses)
  defp ok(body, status \\ 200), do: response(status, body)

  defp response(status, body),
    do:
      {:ok,
       %{
         status: status,
         headers: [],
         body: if(is_binary(body), do: body, else: Jason.encode!(body))
       }}

  defp deadline, do: System.monotonic_time(:millisecond) + 5000
end
