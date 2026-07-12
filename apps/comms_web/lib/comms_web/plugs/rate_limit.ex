defmodule CommsWeb.Plugs.RateLimit do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    limit = Keyword.get(opts, :limit, 120)
    window = Keyword.get(opts, :window, 60)
    key = client_key(conn, Keyword.get(opts, :scope, :ip))

    if CommsWeb.RateLimiter.allow?(key, limit, window) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{error: %{code: "rate_limited", detail: "Too many requests"}})
      )
      |> halt()
    end
  end

  defp client_key(conn, :identity) do
    user_id = conn.assigns[:current_subject] && conn.assigns.current_subject.user_id
    {:identity, user_id || peer(conn)}
  end

  defp client_key(conn, :authentication) do
    params = if match?(%Plug.Conn.Unfetched{}, conn.params), do: %{}, else: conn.params
    tenant = Map.get(params, "tenant_slug", "")
    email = Map.get(params, "email", "")
    account = :crypto.hash(:sha256, "#{tenant}:#{String.downcase(to_string(email))}")
    {:authentication, peer(conn), account}
  end

  defp client_key(conn, :authentication_ip), do: {:authentication_ip, peer(conn)}

  defp client_key(conn, _), do: {:ip, peer(conn)}

  defp peer(%Plug.Conn{remote_ip: remote_ip}), do: remote_ip |> :inet.ntoa() |> to_string()
end
