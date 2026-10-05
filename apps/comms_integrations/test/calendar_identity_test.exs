defmodule CommsIntegrations.CalendarIdentityTest do
  use ExUnit.Case, async: false
  alias CommsCore.AudioCalls.CalendarSync.ExternalIdentityReceipt
  alias CommsIntegrations.Calendar.{Config, IdentityVerifier}

  setup_all do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    {:ok,
     key: key,
     jwks: %{
       "keys" => [
         Map.merge(public, %{"kid" => "calendar-test-key", "use" => "sig", "alg" => "RS256"})
       ]
     }}
  end

  setup do
    nonce = String.duplicate("synthetic-nonce", 4)
    now = System.system_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "aud" => "synthetic-calendar-client",
      "sub" => "stable-provider-subject",
      "nonce" => nonce,
      "iat" => now,
      "exp" => now + 300,
      "email" => "mutable-ignored@example.test"
    }

    config = %Config{
      provider: :google,
      client_id: "synthetic-calendar-client",
      client_secret: "synthetic-calendar-client-secret",
      redirect_uri: "https://workspace.example.test/api/v1/calendar/oauth/google/callback",
      workspace_origin: "https://workspace.example.test"
    }

    {:ok, nonce: nonce, claims: claims, config: config}
  end

  test "signed Google identity binds immutable subject and discards mutable email", context do
    token = sign(context.key, context.claims)

    assert {:ok,
            %ExternalIdentityReceipt{
              provider: :google,
              external_subject: "stable-provider-subject",
              oidc_subject: "stable-provider-subject"
            } = receipt} =
             IdentityVerifier.verify(token, context.jwks, context.config, context.nonce)

    refute Map.has_key?(Map.from_struct(receipt), :email)
    changed = sign(context.key, %{context.claims | "email" => "changed@example.test"})

    assert {:ok, ^receipt} =
             IdentityVerifier.verify(changed, context.jwks, context.config, context.nonce)
  end

  test "issuer audience nonce expiry and authorized-party changes fail closed", context do
    now = System.system_time(:second)

    invalid = [
      {"iss", "https://attacker.example.test"},
      {"aud", "another-client"},
      {"nonce", String.duplicate("different-nonce", 4)},
      {"exp", now},
      {"exp", now + 3601},
      {"iat", now + 31},
      {"iat", now - 3601},
      {"azp", "another-client"},
      {"nbf", now + 1},
      {"sub", ""}
    ]

    for {field, value} <- invalid do
      assert {:error, :invalid_calendar_provider_identity} =
               IdentityVerifier.verify(
                 sign(context.key, Map.put(context.claims, field, value)),
                 context.jwks,
                 context.config,
                 context.nonce
               )
    end
  end

  test "an ambiguous key or external key header cannot control the verifier", context do
    token = sign(context.key, context.claims)

    assert {:error, :invalid_calendar_provider_identity} =
             IdentityVerifier.verify(
               token,
               %{"keys" => context.jwks["keys"] ++ context.jwks["keys"]},
               context.config,
               context.nonce
             )

    token = sign(context.key, context.claims, %{"jku" => "https://attacker.example.test/keys"})

    assert {:error, :invalid_calendar_provider_identity} =
             IdentityVerifier.verify(token, context.jwks, context.config, context.nonce)

    token = sign(context.key, context.claims, %{"kid" => "unknown-key"})

    assert {:error, :invalid_calendar_provider_identity} =
             IdentityVerifier.verify(token, context.jwks, context.config, context.nonce)
  end

  test "RSA keys weaker than 2048 bits are rejected even when their signature verifies",
       context do
    weak = JOSE.JWK.generate_key({:rsa, 1024})
    {_, public} = weak |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    keys = %{"keys" => [Map.put(public, "kid", "calendar-test-key")]}

    assert {:error, :invalid_calendar_provider_identity} =
             IdentityVerifier.verify(
               sign(weak, context.claims),
               keys,
               context.config,
               context.nonce
             )
  end

  test "Microsoft requires exact approved tenant and signed object UUID", context do
    tenant = "635683af-0c58-4d66-8eb5-73f66b66cfdf"
    oid = "5b1022f7-c9ac-4c1f-a86f-625405de99f1"

    config = %{
      context.config
      | provider: :microsoft,
        tenant_id: tenant,
        redirect_uri: "https://workspace.example.test/api/v1/calendar/oauth/microsoft/callback"
    }

    claims =
      Map.merge(context.claims, %{
        "iss" => "https://login.microsoftonline.com/" <> tenant <> "/v2.0",
        "tid" => tenant,
        "oid" => oid
      })

    assert {:ok, %ExternalIdentityReceipt{provider: :microsoft, external_subject: subject}} =
             IdentityVerifier.verify(
               sign(context.key, claims),
               context.jwks,
               config,
               context.nonce
             )

    assert subject == tenant <> ":" <> oid

    for invalid <- [
          %{claims | "tid" => Ecto.UUID.generate()},
          %{claims | "oid" => "mutable-email@example.test"}
        ] do
      assert {:error, :invalid_calendar_provider_identity} =
               IdentityVerifier.verify(
                 sign(context.key, invalid),
                 context.jwks,
                 config,
                 context.nonce
               )
    end
  end

  test "malformed JWT or unbounded JWKS fails with one redacted category", context do
    assert {:error, :invalid_calendar_provider_identity} =
             IdentityVerifier.verify("not-a-jwt", context.jwks, context.config, context.nonce)

    assert {:error, :invalid_calendar_provider_identity} =
             IdentityVerifier.verify(
               sign(context.key, context.claims),
               %{"keys" => List.duplicate(hd(context.jwks["keys"]), 21)},
               context.config,
               context.nonce
             )
  end

  defp sign(key, claims, extra \\ %{}) do
    headers = Map.merge(%{"alg" => "RS256", "kid" => "calendar-test-key"}, extra)
    {_, compact} = key |> JOSE.JWT.sign(headers, claims) |> JOSE.JWS.compact()
    compact
  end
end
