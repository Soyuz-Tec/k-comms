defmodule CommsCore.Accounts.EnterpriseOidcTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{FederatedIdentity, Oidc}
  alias CommsTestSupport.Fixtures

  defmodule Issuer do
    def request(:get, "https://issuer.example.test/.well-known/openid-configuration", _body) do
      {:ok,
       %{
         "issuer" => "https://issuer.example.test",
         "authorization_endpoint" => "https://issuer.example.test/authorize",
         "token_endpoint" => "https://issuer.example.test/token",
         "jwks_uri" => "https://issuer.example.test/jwks",
         "response_types_supported" => ["code"],
         "code_challenge_methods_supported" => ["S256"]
       }}
    end

    def request(:get, "https://issuer.example.test/jwks", _) do
      {:ok, %{"keys" => [Process.get(:issuer_public_key)]}}
    end

    def request(:post, "https://issuer.example.test/token", body) do
      request = URI.decode_query(body)
      Process.put(:issuer_token_request, request)
      {:ok, %{"id_token" => Process.get(:issuer_id_token)}}
    end

    def request(:get, url), do: request(:get, url, "")
  end

  setup do
    old_oidc = Application.get_env(:comms_core, :oidc)
    old_key = Application.get_env(:comms_core, :identity_secret_encryption_key)

    Application.put_env(
      :comms_core,
      :identity_secret_encryption_key,
      "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii"
    )

    config = %{
      enabled: true,
      issuer: "https://issuer.example.test",
      client_id: "kcomms-test-client",
      client_secret: "synthetic-client-secret-only",
      redirect_uri: "https://app.example.test/sign-in/oidc-callback",
      allowed_redirect_uris: ["https://app.example.test/sign-in/oidc-callback"],
      required_acr_values: ["urn:test:mfa"],
      http_adapter: Issuer
    }

    Application.put_env(:comms_core, :oidc, config)
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(key)
    Process.put(:issuer_public_key, Map.put(public, "kid", "synthetic-key"))

    on_exit(fn ->
      if old_oidc,
        do: Application.put_env(:comms_core, :oidc, old_oidc),
        else: Application.delete_env(:comms_core, :oidc)

      if old_key,
        do: Application.put_env(:comms_core, :identity_secret_encryption_key, old_key),
        else: Application.delete_env(:comms_core, :identity_secret_encryption_key)
    end)

    owner = Fixtures.account_fixture(%{password: "enterprise-oidc-fixture-password-123"})

    {:ok, _} =
      Accounts.step_up_view(
        %{current_password: "enterprise-oidc-fixture-password-123"},
        Fixtures.subject(owner)
      )

    %{owner: owner, key: key, config: config}
  end

  test "authorization code binds PKCE, nonce and browser state; email never links accounts", %{
    owner: owner,
    key: key
  } do
    {:ok, start} =
      Accounts.oidc_start(
        %{tenant_slug: owner.tenant.slug, return_to: "https://attacker.test"},
        nil
      )

    query = URI.decode_query(URI.parse(start.authorization_url).query)
    assert query["response_type"] == "code"
    assert query["code_challenge_method"] == "S256"
    sign(key, query["nonce"], %{"sub" => "corporate-subject", "email" => owner.user.email})

    assert {:error, :federated_identity_not_linked} =
             Accounts.oidc_callback(
               %{state: query["state"], code: "synthetic-code"},
               start.browser_binding,
               nil
             )

    refute Repo.exists?(FederatedIdentity)
    request = Process.get(:issuer_token_request)
    assert request["redirect_uri"] == "https://app.example.test/sign-in/oidc-callback"

    assert Base.url_encode64(:crypto.hash(:sha256, request["code_verifier"]), padding: false) ==
             query["code_challenge"]

    assert {:error, :invalid_oidc_state} =
             Accounts.oidc_callback(
               %{state: query["state"], code: "synthetic-code"},
               start.browser_binding,
               nil
             )
  end

  test "explicit linking proves existing session and issuer subject, then sign in resolves that exact key",
       %{owner: owner, key: key} do
    subject = Fixtures.subject(owner)
    {:ok, start} = Accounts.oidc_start(%{tenant_slug: owner.tenant.slug}, subject)
    query = URI.decode_query(URI.parse(start.authorization_url).query)
    sign(key, query["nonce"], %{"sub" => "linked-subject"})

    foreign = Fixtures.account_fixture()

    assert {:error, :invalid_oidc_state} =
             Accounts.oidc_callback(
               %{state: query["state"], code: "code"},
               start.browser_binding,
               Fixtures.subject(foreign)
             )

    assert Process.get(:issuer_token_request) == nil

    assert {:error, :invalid_oidc_state} =
             Accounts.oidc_callback(
               %{state: query["state"], code: "code"},
               "other-browser",
               subject
             )

    assert {:ok, %{linked: true}} =
             Accounts.oidc_callback(
               %{state: query["state"], code: "code"},
               start.browser_binding,
               subject
             )

    {:ok, login} =
      Accounts.oidc_start(%{tenant_slug: owner.tenant.slug, return_to: "/app/files"}, nil)

    login_query = URI.decode_query(URI.parse(login.authorization_url).query)

    sign(key, login_query["nonce"], %{
      "sub" => "linked-subject",
      "email" => "new-mutable-email@example.test"
    })

    assert {:ok, %{authentication: auth, return_to: "/app/files"}} =
             Accounts.oidc_callback(
               %{state: login_query["state"], code: "code"},
               login.browser_binding,
               nil
             )

    assert auth.user.id == owner.user.id
    assert auth.user.email == owner.user.email
  end

  test "foreign issuer, audience, assurance, expiry, nonce and signature are rejected", %{
    key: key,
    config: config
  } do
    {_, public} = JOSE.JWK.to_public_map(key)
    jwks = %{"keys" => [Map.put(public, "kid", "synthetic-key")]}
    nonce_hash = Base.encode64(:crypto.hash(:sha256, "expected-nonce"))

    for attrs <- [
          %{"iss" => "https://foreign.test"},
          %{"aud" => "different-client"},
          %{"acr" => "urn:test:password"},
          %{"exp" => System.system_time(:second) - 1},
          %{"auth_time" => nil},
          %{"auth_time" => System.system_time(:second) - 301},
          %{"auth_time" => System.system_time(:second) + 31},
          %{"nonce" => "wrong-nonce"},
          %{"aud" => [config.client_id, "other"], "azp" => "other"}
        ] do
      token = sign(key, "expected-nonce", attrs)
      assert {:error, :invalid_oidc_token} = Oidc.validate_token(token, jwks, config, nonce_hash)
    end

    other_key = JOSE.JWK.generate_key({:rsa, 2048})
    token = sign(other_key, "expected-nonce", %{})
    assert {:error, :invalid_oidc_token} = Oidc.validate_token(token, jwks, config, nonce_hash)

    weak_key = JOSE.JWK.generate_key({:rsa, 1024})
    {_, weak_public} = JOSE.JWK.to_public_map(weak_key)
    weak_token = sign(weak_key, "expected-nonce", %{})
    {:ok, weak_modulus} = Base.url_decode64(weak_public["n"], padding: false)
    padded_modulus = :binary.copy(<<0>>, 256 - byte_size(weak_modulus)) <> weak_modulus

    padded_jwks = %{
      "keys" => [
        weak_public
        |> Map.put("kid", "synthetic-key")
        |> Map.put("n", Base.url_encode64(padded_modulus, padding: false))
      ]
    }

    assert {:error, :invalid_oidc_token} =
             Oidc.validate_token(weak_token, padded_jwks, config, nonce_hash)

    token = sign(key, "expected-nonce", %{})
    assert {:ok, _} = Oidc.validate_token(token, jwks, config, nonce_hash)
  end

  test "corporate step-up proves the same linked subject and active initiating session", %{
    owner: owner,
    key: key
  } do
    Repo.insert!(%FederatedIdentity{
      tenant_id: owner.tenant.id,
      user_id: owner.user.id,
      issuer: "https://issuer.example.test",
      subject: "existing-linked-subject"
    })

    session = Repo.get!(CommsCore.Accounts.Session, owner.session.id)
    Repo.update!(Ecto.Changeset.change(session, step_up_at: nil))
    subject = Fixtures.subject(owner)

    {:ok, start} =
      Accounts.oidc_start(%{tenant_slug: owner.tenant.slug, purpose: "step_up"}, subject)

    query = URI.decode_query(URI.parse(start.authorization_url).query)
    assert query["prompt"] == "login"
    assert query["max_age"] == "300"
    sign(key, query["nonce"], %{"sub" => "different-subject"})

    assert {:error, :federated_identity_not_linked} =
             Accounts.oidc_callback(
               %{state: query["state"], code: "code"},
               start.browser_binding,
               subject
             )

    assert Repo.get!(CommsCore.Accounts.Session, owner.session.id).step_up_at == nil

    {:ok, retry} =
      Accounts.oidc_start(%{tenant_slug: owner.tenant.slug, purpose: "step_up"}, subject)

    retry_query = URI.decode_query(URI.parse(retry.authorization_url).query)
    sign(key, retry_query["nonce"], %{"sub" => "existing-linked-subject"})

    assert {:ok, %{linked: true}} =
             Accounts.oidc_callback(
               %{state: retry_query["state"], code: "code"},
               retry.browser_binding,
               subject
             )

    assert Repo.get!(CommsCore.Accounts.Session, owner.session.id).step_up_at
  end

  test "missing or insecure configuration fails closed" do
    Application.put_env(:comms_core, :oidc, %{enabled: false})
    assert {:error, :oidc_not_configured} = Oidc.configuration()
    Application.put_env(:comms_core, :oidc, %{enabled: true, issuer: "http://localhost:1234"})
    assert {:error, :oidc_not_configured} = Oidc.configuration()
  end

  defp sign(key, nonce, attrs) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "https://issuer.example.test",
          "sub" => "corporate-subject",
          "aud" => "kcomms-test-client",
          "nonce" => nonce,
          "auth_time" => now,
          "exp" => now + 300,
          "iat" => now,
          "acr" => "urn:test:mfa"
        },
        attrs
      )

    {_, token} =
      JOSE.JWT.sign(key, %{"alg" => "RS256", "kid" => "synthetic-key"}, claims)
      |> JOSE.JWS.compact()

    Process.put(:issuer_id_token, token)
    token
  end
end
