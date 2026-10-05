defmodule CommsCore.Accounts.Oidc do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessControl,
    AuthChallenge,
    FederatedIdentity,
    IdentitySecretBox,
    OidcHttp,
    Projector,
    Session,
    SessionAuthority,
    User
  }

  alias CommsCore.Accounts.Sessions.{Persistence, RefreshTokens}
  alias CommsCore.{Administration, Repo}

  def start(attrs, subject) do
    operation =
      if subject && value(attrs, :purpose) == "step_up",
        do: "step_up",
        else: if(subject, do: "link", else: "sign_in")

    with {:ok, config} <- configuration(),
         {:ok, tenant} <- Administration.active_tenant_by_slug(value(attrs, :tenant_slug)),
         :ok <- authorize_operation(subject, tenant.id, operation),
         {:ok, discovery} <- discovery(config) do
      state = random_token()
      nonce = random_token()
      verifier = random_token() <> random_token()
      binding = random_token()
      id = Ecto.UUID.generate()

      with {:ok, encrypted} <- IdentitySecretBox.encrypt(verifier, context(tenant.id, id)),
           {:ok, _challenge} <-
             Repo.insert(%AuthChallenge{
               id: id,
               tenant_id: tenant.id,
               user_id: if(subject, do: value(subject, :user_id)),
               kind: "oidc",
               token_hash: digest(state),
               expires_at: DateTime.add(Persistence.now(), 300),
               payload: %{
                 "verifier" => encode_box(encrypted),
                 "nonce_hash" => Base.encode64(digest(nonce)),
                 "binding_hash" => Base.encode64(digest(binding)),
                 "redirect_uri" => config.redirect_uri,
                 "operation" => operation,
                 "return_to" => safe_return(value(attrs, :return_to)),
                 "link_session_id" => if(subject, do: value(subject, :session_id))
               }
             }) do
        query =
          URI.encode_query(%{
            response_type: "code",
            client_id: config.client_id,
            redirect_uri: config.redirect_uri,
            scope: "openid profile email",
            state: state,
            nonce: nonce,
            code_challenge: Base.url_encode64(digest(verifier), padding: false),
            code_challenge_method: "S256",
            acr_values: Enum.join(config.required_acr_values, " "),
            max_age: "300",
            prompt: "login"
          })

        {:ok,
         %{
           authorization_url: discovery["authorization_endpoint"] <> "?" <> query,
           browser_binding: binding,
           state: state,
           expires_in: 300
         }}
      end
    end
  end

  def callback(attrs, binding, subject) do
    with {:ok, config} <- configuration(),
         {:ok, challenge} <- consume_challenge(value(attrs, :state), binding, subject),
         true <- challenge.payload["redirect_uri"] == config.redirect_uri,
         {:ok, discovery} <- discovery(config),
         {:ok, verifier} <-
           IdentitySecretBox.decrypt(
             decode_box(challenge.payload["verifier"]),
             context(challenge.tenant_id, challenge.id)
           ),
         code when is_binary(code) and byte_size(code) in 1..4096 <- value(attrs, :code),
         {:ok, tokens} when is_map(tokens) <-
           http(config).request(
             :post,
             discovery["token_endpoint"],
             URI.encode_query(%{
               grant_type: "authorization_code",
               code: code,
               client_id: config.client_id,
               client_secret: config.client_secret,
               redirect_uri: config.redirect_uri,
               code_verifier: verifier
             })
           ),
         id_token when is_binary(id_token) and byte_size(id_token) <= 32_768 <- tokens["id_token"],
         {:ok, jwks} <- http(config).request(:get, discovery["jwks_uri"]),
         {:ok, claims} <- validate_token(id_token, jwks, config, challenge.payload["nonce_hash"]) do
      finish(challenge, claims, config, subject)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_oidc_response}
    end
  end

  # Signature, algorithm and claims checks are applied to keys from the exact discovered issuer.
  def validate_token(token, %{"keys" => keys}, config, nonce_hash)
      when is_list(keys) and length(keys) <= 20 do
    {_, header} = token |> JOSE.JWT.peek_protected() |> JOSE.JWS.to_map()

    key =
      Enum.find(keys, fn key ->
        key["kid"] == header["kid"] and key["kty"] == "RSA" and key["use"] in [nil, "sig"] and
          key["alg"] in [nil, "RS256"]
      end)

    with true <- header["alg"] == "RS256" and is_binary(header["kid"]) and not is_nil(key),
         true <- Enum.count(keys, &(&1["kid"] == header["kid"])) == 1,
         {:ok, modulus} <- Base.url_decode64(key["n"], padding: false),
         true <- byte_size(modulus) >= 256 and :binary.first(modulus) != 0,
         true <- byte_size(modulus) > 256 or :binary.first(modulus) >= 128,
         {true, jwt, _} <- JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token),
         claims = jwt.fields,
         now = System.system_time(:second),
         true <- claims["iss"] == config.issuer,
         true <- valid_audience?(claims, config.client_id),
         true <- is_binary(claims["sub"]) and byte_size(claims["sub"]) in 1..512,
         true <- is_integer(claims["exp"]) and claims["exp"] > now and claims["exp"] <= now + 3600,
         true <-
           is_integer(claims["iat"]) and claims["iat"] <= now + 30 and claims["iat"] >= now - 3600,
         true <- is_nil(claims["nbf"]) or (is_integer(claims["nbf"]) and claims["nbf"] <= now),
         true <-
           is_binary(claims["nonce"]) and
             constant_equal(Base.encode64(digest(claims["nonce"])), nonce_hash),
         true <-
           is_integer(claims["auth_time"]) and claims["auth_time"] >= now - 300 and
             claims["auth_time"] <= now + 30,
         true <- claims["acr"] in config.required_acr_values do
      {:ok, claims}
    else
      _ -> {:error, :invalid_oidc_token}
    end
  rescue
    _ -> {:error, :invalid_oidc_token}
  end

  def validate_token(_, _, _, _), do: {:error, :invalid_oidc_token}

  def configuration do
    config = Application.get_env(:comms_core, :oidc, %{})

    with true <- config[:enabled] == true,
         issuer when is_binary(issuer) <- config[:issuer],
         :ok <- https_url(issuer),
         client_id when is_binary(client_id) and byte_size(client_id) in 1..512 <-
           config[:client_id],
         secret when is_binary(secret) and byte_size(secret) >= 16 <- config[:client_secret],
         redirect_uri when is_binary(redirect_uri) <- config[:redirect_uri],
         :ok <- https_url(redirect_uri),
         true <- redirect_uri in (config[:allowed_redirect_uris] || []),
         acr when is_list(acr) and length(acr) in 1..10 <- config[:required_acr_values],
         true <- Enum.all?(acr, &(is_binary(&1) and byte_size(&1) in 1..256)) do
      {:ok,
       %{
         issuer: issuer,
         client_id: client_id,
         client_secret: secret,
         redirect_uri: redirect_uri,
         required_acr_values: acr,
         http_adapter: config[:http_adapter] || OidcHttp
       }}
    else
      _ -> {:error, :oidc_not_configured}
    end
  end

  defp discovery(config) do
    with {:ok, doc} when is_map(doc) <-
           http(config).request(
             :get,
             String.trim_trailing(config.issuer, "/") <> "/.well-known/openid-configuration"
           ),
         true <- doc["issuer"] == config.issuer,
         true <-
           is_list(doc["response_types_supported"]) and "code" in doc["response_types_supported"],
         true <-
           is_list(doc["code_challenge_methods_supported"]) and
             "S256" in doc["code_challenge_methods_supported"],
         true <-
           Enum.all?(["authorization_endpoint", "token_endpoint", "jwks_uri"], fn field ->
             trusted_endpoint?(doc[field], config.issuer)
           end) do
      {:ok, doc}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_oidc_discovery}
    end
  end

  defp consume_challenge(state, binding, subject)
       when is_binary(state) and byte_size(state) <= 256 and is_binary(binding) and
              byte_size(binding) <= 256 do
    Repo.transaction(fn ->
      challenge =
        Repo.one(
          from(c in AuthChallenge,
            where: c.kind == "oidc" and c.token_hash == ^digest(state),
            lock: "FOR UPDATE"
          )
        )

      with %AuthChallenge{consumed_at: nil} <- challenge,
           true <- DateTime.compare(challenge.expires_at, Persistence.now()) == :gt,
           true <-
             constant_equal(challenge.payload["binding_hash"], Base.encode64(digest(binding))),
           :ok <- verify_link_session(challenge, subject) do
        Repo.update!(Ecto.Changeset.change(challenge, consumed_at: Persistence.now()))
      else
        _ -> Repo.rollback(:invalid_oidc_state)
      end
    end)
  end

  defp consume_challenge(_, _, _), do: {:error, :invalid_oidc_state}

  defp finish(challenge, claims, config, subject) do
    Repo.transaction(
      fn ->
        deadline = System.monotonic_time(:millisecond) + 30_000
        set_effect_budget!(deadline)

        if challenge.user_id do
          authorize_final_operation!(challenge, subject, deadline)
        else
          case Administration.lock_call_policy(challenge.tenant_id) do
            {:ok, _policy} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        # Federation always resolves iss/sub, never mutable email attributes.
        identity =
          Repo.get_by(FederatedIdentity,
            tenant_id: challenge.tenant_id,
            issuer: config.issuer,
            subject: claims["sub"]
          )

        set_effect_budget!(deadline)

        unless DateTime.compare(challenge.expires_at, Persistence.now()) == :gt,
          do: Repo.rollback(:invalid_oidc_state)

        validate_completion_time!(claims)

        if challenge.user_id do
          # Recheck expiry and recent proof after all waits while the complete
          # initiating identity remains locked until link/step-up commit.
          authorize_operation(subject, challenge.tenant_id, challenge.payload["operation"])
          |> case do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        if challenge.payload["operation"] == "step_up" do
          if is_nil(identity) or identity.user_id != challenge.user_id,
            do: Repo.rollback(:federated_identity_not_linked)

          now = System.system_time(:second)

          if not is_integer(claims["auth_time"]) or claims["auth_time"] < now - 300 or
               claims["auth_time"] > now + 30,
             do: Repo.rollback(:oidc_recent_authentication_required)

          session =
            Repo.one(
              from(session in CommsCore.Accounts.Session,
                where:
                  session.id == ^challenge.payload["link_session_id"] and
                    session.user_id == ^challenge.user_id and
                    session.tenant_id == ^challenge.tenant_id and is_nil(session.revoked_at) and
                    session.expires_at > ^Persistence.now() and
                    session.absolute_expires_at > ^Persistence.now(),
                lock: "FOR UPDATE"
              )
            ) || Repo.rollback(:session_expired)

          Repo.update!(
            Ecto.Changeset.change(%CommsCore.Accounts.Session{} = session,
              step_up_at: Persistence.now(),
              mfa_verified_at: Persistence.now()
            )
          )

          Persistence.insert_audit!(subject, "identity.oidc_step_up", "session", session.id, %{
            issuer: config.issuer,
            acr: claims["acr"]
          })

          %{linked: true, return_to: challenge.payload["return_to"]}
        else
          if challenge.user_id do
            case identity do
              nil ->
                Repo.insert!(%FederatedIdentity{
                  tenant_id: challenge.tenant_id,
                  user_id: challenge.user_id,
                  issuer: config.issuer,
                  subject: claims["sub"]
                })

              %{user_id: user_id} when user_id == challenge.user_id ->
                :ok

              _ ->
                Repo.rollback(:federated_identity_conflict)
            end

            Persistence.insert_audit!(
              subject,
              "identity.oidc_linked",
              "user",
              challenge.user_id,
              %{
                issuer: config.issuer
              }
            )

            %{linked: true, return_to: challenge.payload["return_to"]}
          else
            if is_nil(identity), do: Repo.rollback(:federated_identity_not_linked)

            user =
              Repo.one(
                from(u in User,
                  where:
                    u.id == ^identity.user_id and u.tenant_id == ^challenge.tenant_id and
                      u.status == :active and u.account_type == :human,
                  lock: "FOR UPDATE"
                )
              ) || Repo.rollback(:invalid_credentials)

            set_effect_budget!(deadline)

            unless DateTime.compare(challenge.expires_at, Persistence.now()) == :gt,
              do: Repo.rollback(:invalid_oidc_state)

            validate_completion_time!(claims)

            tenant =
              case Administration.active_tenant(user.tenant_id) do
                {:ok, tenant} -> tenant
                {:error, reason} -> Repo.rollback(reason)
              end

            {:ok, device} =
              Persistence.upsert_device(user, %{name: "Corporate SSO", platform: "web"})

            {:ok, session, refresh_token} = RefreshTokens.create(user, device)

            session =
              Repo.update!(
                Ecto.Changeset.change(%Session{} = session,
                  authentication_method: "oidc",
                  mfa_verified_at: Persistence.now(),
                  step_up_at: Persistence.now()
                )
              )

            Persistence.insert_audit!(
              %{tenant_id: user.tenant_id, user_id: user.id},
              "identity.oidc_sign_in",
              "user",
              user.id,
              %{issuer: config.issuer, acr: claims["acr"]}
            )

            %{
              authentication:
                Projector.authentication(%{
                  user: user,
                  tenant: tenant,
                  device: device,
                  session: session,
                  refresh_token: refresh_token
                }),
              return_to: challenge.payload["return_to"]
            }
          end
        end
      end,
      timeout: 35_000
    )
  rescue
    _ -> {:error, :federated_identity_conflict}
  end

  defp authorize_final_operation!(challenge, subject, deadline) do
    with true <-
           is_map(subject) and challenge.user_id == value(subject, :user_id) and
             challenge.tenant_id == value(subject, :tenant_id) and
             challenge.payload["link_session_id"] == value(subject, :session_id),
         {:ok, %{tenant_id: tenant_id, user_id: user_id, session_id: session_id}} <-
           SessionAuthority.lock(subject, deadline),
         true <-
           tenant_id == challenge.tenant_id and user_id == challenge.user_id and
             session_id == challenge.payload["link_session_id"] do
      :ok
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp set_effect_budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond) - 1_000
    if remaining <= 0, do: Repo.rollback(:forbidden)

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $1, true)",
      [Integer.to_string(remaining)]
    )
  end

  defp validate_completion_time!(claims) do
    now = System.system_time(:second)

    unless is_integer(claims["exp"]) and claims["exp"] > now and
             is_integer(claims["auth_time"]) and claims["auth_time"] >= now - 300 and
             claims["auth_time"] <= now + 30,
           do: Repo.rollback(:invalid_oidc_token)
  end

  defp authorize_operation(subject, tenant_id, "step_up") do
    with {:ok, %{tenant_id: ^tenant_id, account_type: :human}} <-
           AccessControl.access_grant(subject) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_operation(subject, tenant_id, _), do: authorize_link(subject, tenant_id)
  defp authorize_link(nil, _), do: :ok

  defp authorize_link(subject, tenant_id) do
    with {:ok, %{tenant_id: ^tenant_id, account_type: :human, step_up_recent?: true}} <-
           AccessControl.access_grant(subject) do
      :ok
    else
      _ -> {:error, :step_up_required}
    end
  end

  defp verify_link_session(%{user_id: nil}, nil), do: :ok

  defp verify_link_session(challenge, subject) when is_map(subject) do
    with true <-
           challenge.user_id == value(subject, :user_id) and
             challenge.payload["link_session_id"] == value(subject, :session_id),
         :ok <- authorize_operation(subject, challenge.tenant_id, challenge.payload["operation"]) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp verify_link_session(_, _), do: {:error, :forbidden}

  defp valid_audience?(%{"aud" => audience} = claims, client_id) when is_list(audience),
    do: client_id in audience and claims["azp"] == client_id

  defp valid_audience?(claims, client_id),
    do: claims["aud"] == client_id and claims["azp"] in [nil, client_id]

  defp https_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil}
      when is_binary(host) ->
        :ok

      _ ->
        {:error, :invalid_oidc_url}
    end
  end

  defp https_url(_), do: {:error, :invalid_oidc_url}

  defp trusted_endpoint?(url, issuer) do
    https_url(url) == :ok and URI.parse(url).host == URI.parse(issuer).host
  end

  defp safe_return(path) when is_binary(path) do
    if byte_size(path) <= 2048 and
         (path == "/app" or String.starts_with?(path, "/app/") or
            String.starts_with?(path, "/app?")) and
         not String.contains?(path, ["\\", "\r", "\n", "#"]) and
         not String.starts_with?(path, "//"), do: path, else: "/app"
  end

  defp safe_return(_), do: "/app"
  defp http(config), do: config.http_adapter

  defp encode_box(box),
    do:
      Map.new(box, fn {key, value} ->
        {Atom.to_string(key), if(key == :key_id, do: value, else: Base.encode64(value))}
      end)

  defp decode_box(box),
    do:
      Map.new([:ciphertext, :nonce, :tag, :key_id], fn key ->
        {key,
         if(key == :key_id,
           do: box[Atom.to_string(key)],
           else: Base.decode64!(box[Atom.to_string(key)])
         )}
      end)

  defp context(tenant, id), do: %{tenant_id: tenant, identity_secret_id: id, version: 1}
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)

  defp constant_equal(a, b) when is_binary(a) and is_binary(b),
    do: byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)

  defp constant_equal(_, _), do: false
  defp value(map, key), do: Persistence.value(map, key)
end
