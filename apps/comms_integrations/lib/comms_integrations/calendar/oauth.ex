defmodule CommsIntegrations.Calendar.OAuth do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.{OAuthRequest, TokenReceipt}
  alias CommsIntegrations.Calendar.{Config, Http, IdentityVerifier}

  def authorization_url(provider, state, nonce, verifier) do
    with {:ok, config} <- Config.load(provider),
         true <- token?(state, 32, 256) and token?(nonce, 32, 256),
         true <-
           is_binary(verifier) and byte_size(verifier) in 43..128 and
             Regex.match?(~r/^[A-Za-z0-9_.~-]+$/, verifier) do
      query = %{
        response_type: "code",
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        scope: Enum.join(Config.scopes(provider), " "),
        state: state,
        nonce: nonce,
        code_challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        code_challenge_method: "S256",
        prompt: "consent"
      }

      query = if provider == :google, do: Map.put(query, :access_type, "offline"), else: query
      {:ok, Config.endpoints(config).authorize <> "?" <> URI.encode_query(query)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_oauth_request}
    end
  end

  def token(request, opts \\ [])

  def token(%OAuthRequest{deadline_ms: deadline} = request, opts) when is_integer(deadline) do
    request = %{
      request
      | deadline_ms: min(request.deadline_ms, System.monotonic_time(:millisecond) + 5_000)
    }

    with {:ok, config} <- Config.load(request.provider),
         {:ok, params} <- token_params(request, config),
         {:ok, response} <-
           Http.request(
             :post,
             Config.endpoints(config).token,
             [
               {"content-type", "application/x-www-form-urlencoded"},
               {"accept", "application/json"}
             ],
             URI.encode_query(params),
             request.deadline_ms,
             opts
           ),
         {:ok, body} <- token_response(response),
         {:ok, receipt} <- parse_token(body, request, config, opts) do
      {:ok, receipt}
    end
  end

  def token(_, _), do: {:error, :invalid_calendar_oauth_request}

  def revoke(provider, refresh_token, deadline, opts \\ [])

  def revoke(:microsoft, token, deadline, _opts) when is_binary(token) and is_integer(deadline),
    do: {:ok, :external_unconfirmed}

  def revoke(:google, token, deadline, opts) when is_binary(token) and is_integer(deadline) do
    with {:ok, config} <- Config.load(:google),
         true <- token?(token, 1, 16_384),
         {:ok, response} <-
           Http.request(
             :post,
             Config.endpoints(config).revoke,
             [{"content-type", "application/x-www-form-urlencoded"}],
             URI.encode_query(%{token: token}),
             deadline,
             opts
           ) do
      if response.status == 200,
        do: {:ok, :confirmed},
        else: {:error, :calendar_revocation_unconfirmed}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_oauth_request}
    end
  end

  def revoke(_, _, _, _), do: {:error, :invalid_calendar_oauth_request}

  defp token_params(%OAuthRequest{operation: :exchange} = request, config) do
    if token?(request.code, 1, 4096) and token?(request.verifier, 43, 128) and
         token?(request.nonce, 32, 256) do
      {:ok,
       %{
         grant_type: "authorization_code",
         code: request.code,
         code_verifier: request.verifier,
         client_id: config.client_id,
         client_secret: config.client_secret,
         redirect_uri: config.redirect_uri
       }}
    else
      {:error, :invalid_calendar_oauth_request}
    end
  end

  defp token_params(%OAuthRequest{operation: :refresh} = request, config) do
    if token?(request.refresh_token, 1, 16_384) do
      {:ok,
       %{
         grant_type: "refresh_token",
         refresh_token: request.refresh_token,
         client_id: config.client_id,
         client_secret: config.client_secret
       }}
    else
      {:error, :invalid_calendar_oauth_request}
    end
  end

  defp token_params(_, _), do: {:error, :invalid_calendar_oauth_request}

  defp token_response(%{status: 200, body: body}), do: Http.json(body)

  defp token_response(%{status: status, body: body}) when status in [400, 401, 403] do
    case Http.json(body) do
      {:ok, %{"error" => "invalid_grant"}} -> {:error, :calendar_reauthorization_required}
      _ -> {:error, :calendar_provider_permission_denied}
    end
  end

  defp token_response(_), do: {:error, :calendar_provider_unavailable}

  defp parse_token(body, request, config, opts) do
    with true <- body["token_type"] == "Bearer",
         true <- token?(body["access_token"], 1, 16_384),
         true <- is_integer(body["expires_in"]) and body["expires_in"] in 1..86_400,
         true <- is_nil(body["refresh_token"]) or token?(body["refresh_token"], 1, 16_384),
         true <- request.operation == :refresh or token?(body["refresh_token"], 1, 16_384),
         {:ok, scopes} <- scopes(body["scope"], config.provider),
         {:ok, identity} <- identity(body, request, config, opts) do
      {:ok,
       %TokenReceipt{
         provider: config.provider,
         access_token: body["access_token"],
         refresh_token: body["refresh_token"],
         identity: identity,
         scopes: scopes,
         expires_at: DateTime.add(DateTime.utc_now(), body["expires_in"])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_provider_response}
    end
  end

  defp identity(_body, %OAuthRequest{operation: :refresh}, _config, _opts), do: {:ok, nil}

  defp identity(body, request, config, opts) do
    with true <- token?(body["id_token"], 1, 32_768),
         {:ok, %{status: 200, body: jwks}} <-
           Http.request(
             :get,
             Config.endpoints(config).jwks,
             [{"accept", "application/json"}],
             "",
             request.deadline_ms,
             opts
           ),
         {:ok, keys} <- Http.json(jwks) do
      IdentityVerifier.verify(body["id_token"], keys, config, request.nonce)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_provider_identity}
    end
  end

  defp scopes(value, provider) when is_binary(value) and byte_size(value) in 1..4096 do
    scopes =
      value
      |> String.split(" ", trim: true)
      |> Enum.map(&normalize_scope(&1, provider))
      |> Enum.uniq()
      |> Enum.sort()

    allowed = Config.scopes(provider)

    required =
      if provider == :google,
        do: "https://www.googleapis.com/auth/calendar.events.owned",
        else: "https://graph.microsoft.com/Calendars.ReadWrite"

    if length(scopes) <= length(allowed) and required in scopes and
         Enum.all?(scopes, &(&1 in allowed)),
       do: {:ok, scopes},
       else: {:error, :calendar_provider_scope_denied}
  end

  defp scopes(_, _), do: {:error, :calendar_provider_scope_denied}

  defp normalize_scope("Calendars.ReadWrite", :microsoft),
    do: "https://graph.microsoft.com/Calendars.ReadWrite"

  defp normalize_scope(scope, _), do: scope

  defp token?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and
        not String.contains?(value, ["\r", "\n", "\0"])
end
