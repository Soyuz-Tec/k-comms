defmodule CommsCore.Accounts.OidcHttp do
  @moduledoc false
  @maximum_body 262_144

  def request(method, url, body \\ "") do
    uri = URI.parse(url)

    options = [
      timeout: 5_000,
      connect_timeout: 3_000,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(uri.host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    request =
      if method == :get do
        {String.to_charlist(url), [{~c"accept", ~c"application/json"}]}
      else
        {String.to_charlist(url), [{~c"accept", ~c"application/json"}],
         ~c"application/x-www-form-urlencoded", body}
      end

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, 200, _}, _, response}} when byte_size(response) <= @maximum_body ->
        Jason.decode(response)

      _ ->
        {:error, :oidc_provider_unavailable}
    end
  rescue
    _ -> {:error, :oidc_provider_unavailable}
  end
end
