defmodule CommsIntegrations.Calendar.Config do
  @moduledoc false
  @derive {Inspect, except: [:client_secret]}
  @enforce_keys [:provider, :client_id, :client_secret, :redirect_uri, :workspace_origin]
  defstruct [:provider, :client_id, :client_secret, :redirect_uri, :workspace_origin, :tenant_id]

  @google_scopes ["openid", "https://www.googleapis.com/auth/calendar.events.owned"]
  @microsoft_scopes [
    "openid",
    "profile",
    "offline_access",
    "https://graph.microsoft.com/Calendars.ReadWrite"
  ]

  def load(provider) when provider in [:google, :microsoft] do
    providers = Application.get_env(:comms_integrations, :calendar_providers, %{})
    config = providers[provider] || %{}

    with true <- config[:enabled] == true,
         true <- bounded?(config[:client_id], 1, 512),
         true <- bounded?(config[:client_secret], 16, 4096),
         :ok <- redirect(config[:redirect_uri], provider),
         :ok <- origin(config[:workspace_origin]),
         true <- same_origin?(config[:redirect_uri], config[:workspace_origin]),
         :ok <- tenant(provider, config[:tenant_id]) do
      {:ok,
       %__MODULE__{
         provider: provider,
         client_id: config[:client_id],
         client_secret: config[:client_secret],
         redirect_uri: config[:redirect_uri],
         workspace_origin: config[:workspace_origin],
         tenant_id: config[:tenant_id]
       }}
    else
      _ -> {:error, :calendar_provider_not_configured}
    end
  end

  def load(_), do: {:error, :calendar_provider_not_configured}
  def scopes(:google), do: @google_scopes
  def scopes(:microsoft), do: @microsoft_scopes

  def endpoints(%__MODULE__{provider: :google}) do
    %{
      authorize: "https://accounts.google.com/o/oauth2/v2/auth",
      token: "https://oauth2.googleapis.com/token",
      revoke: "https://oauth2.googleapis.com/revoke",
      jwks: "https://www.googleapis.com/oauth2/v3/certs",
      userinfo: "https://openidconnect.googleapis.com/v1/userinfo",
      events: "https://www.googleapis.com/calendar/v3/calendars/primary/events",
      issuer: "https://accounts.google.com"
    }
  end

  def endpoints(%__MODULE__{provider: :microsoft, tenant_id: tenant}) do
    base = "https://login.microsoftonline.com/" <> tenant

    %{
      authorize: base <> "/oauth2/v2.0/authorize",
      token: base <> "/oauth2/v2.0/token",
      jwks: base <> "/discovery/v2.0/keys",
      events: "https://graph.microsoft.com/v1.0/me/calendar/events",
      userinfo: "https://graph.microsoft.com/oidc/userinfo",
      issuer: base <> "/v2.0"
    }
  end

  defp redirect(url, provider) do
    uri = URI.parse(if(is_binary(url), do: url, else: ""))
    expected = "/api/v1/calendar/oauth/" <> Atom.to_string(provider) <> "/callback"
    if https?(uri) and uri.path == expected and is_nil(uri.query), do: :ok, else: :error
  end

  defp origin(url) do
    uri = URI.parse(if(is_binary(url), do: url, else: ""))
    if https?(uri) and uri.path in [nil, "", "/"] and is_nil(uri.query), do: :ok, else: :error
  end

  defp https?(uri),
    do:
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
        is_nil(uri.userinfo) and is_nil(uri.fragment) and uri.port == 443

  defp same_origin?(url, origin) do
    a = URI.parse(url)
    b = URI.parse(origin)
    {a.scheme, a.host, a.port} == {b.scheme, b.host, b.port}
  end

  defp tenant(:google, _), do: :ok

  defp tenant(:microsoft, id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> :ok
      _ -> :error
    end
  end

  defp bounded?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and
        not String.contains?(value, ["\r", "\n", "\0"])
end
