defmodule CommsWeb.EnterpriseIdentityController do
  use CommsWeb, :controller
  alias CommsCore.Accounts
  alias CommsWeb.Token
  @cookie "kcomms_oidc_binding"

  def complete_mfa(conn, params) do
    with {:ok, result} <-
           Accounts.complete_mfa_sign_in(params["challenge_token"], params["code"], %{}) do
      conn |> put_resp_header("cache-control", "no-store") |> json(Token.issue(result))
    end
  end

  def oidc_start(conn, params), do: start_oidc(conn, params, nil)

  def oidc_step_up(conn, params),
    do: start_oidc(conn, Map.put(params, "purpose", "step_up"), conn.assigns.current_subject)

  def oidc_link(conn, params), do: start_oidc(conn, params, conn.assigns.current_subject)

  def oidc_callback(conn, params) do
    callback(conn, params, nil)
  end

  def oidc_link_callback(conn, params) do
    callback(conn, params, conn.assigns.current_subject)
  end

  def security(conn, _params) do
    with {:ok, result} <- Accounts.identity_security(conn.assigns.current_subject),
         do: json(conn, %{data: result})
  end

  def enroll_mfa(conn, _params) do
    with {:ok, result} <- Accounts.enroll_mfa(conn.assigns.current_subject),
         do: private_json(conn, result)
  end

  def confirm_mfa(conn, params) do
    with {:ok, result} <- Accounts.confirm_mfa(params["code"], conn.assigns.current_subject),
         do: receipt(conn, result)
  end

  def disable_mfa(conn, params) do
    with {:ok, result} <- Accounts.disable_mfa(params["code"], conn.assigns.current_subject),
         do: receipt(conn, result)
  end

  def recovery_codes(conn, params) do
    with {:ok, result} <-
           Accounts.rotate_mfa_recovery(params["code"], conn.assigns.current_subject),
         do: receipt(conn, result)
  end

  def availability(conn, _params) do
    with {:ok, result} <- Accounts.availability(conn.assigns.current_subject),
         do: json(conn, %{data: result})
  end

  def update_availability(conn, params) do
    with {:ok, result} <- Accounts.update_availability(params, conn.assigns.current_subject),
         do: json(conn, %{data: result})
  end

  defp start_oidc(conn, params, subject) do
    with {:ok, result} <- Accounts.oidc_start(params, subject) do
      conn
      |> put_resp_cookie(@cookie, result.browser_binding,
        http_only: true,
        secure: conn.scheme == :https,
        same_site: "Lax",
        max_age: 300,
        path: "/api/v1",
        sign: true
      )
      |> put_resp_header("cache-control", "no-store")
      |> json(%{authorization_url: result.authorization_url, expires_in: result.expires_in})
    end
  end

  defp callback(conn, params, subject) do
    conn = fetch_cookies(conn, signed: [@cookie])
    binding = conn.cookies[@cookie]

    with {:ok, result} <- Accounts.oidc_callback(params, binding, subject) do
      conn =
        conn
        |> delete_resp_cookie(@cookie, path: "/api/v1")
        |> put_resp_header("cache-control", "no-store")

      case result do
        %{authentication: auth} ->
          json(conn, %{session: Token.issue(auth), return_to: result.return_to})

        %{linked: true} ->
          json(conn, result)
      end
    end
  end

  defp receipt(conn, result) do
    Enum.each(Map.get(result, :revoked_session_ids, []), fn id ->
      CommsWeb.Endpoint.broadcast("session_socket:#{id}", "disconnect", %{})
    end)

    private_json(conn, Map.drop(result, [:revoked_session_ids]))
  end

  defp private_json(conn, data),
    do: conn |> put_resp_header("cache-control", "no-store") |> json(%{data: data})
end
