defmodule CommsWeb.SessionController do
  use CommsWeb, :controller

  alias CommsCore.Accounts
  alias CommsWeb.Token

  def create(conn, params) do
    device = params["device"] || %{}

    with {:ok, result} <-
           Accounts.authenticate(
             params["tenant_slug"],
             params["email"],
             params["password"],
             device
           ) do
      CommsObservability.execute([:auth, :success], %{count: 1}, %{tenant_id: result.tenant.id})
      json(conn, Token.issue(result))
    else
      {:error, reason} = error ->
        CommsObservability.execute([:auth, :failure], %{count: 1}, %{reason: reason})
        error
    end
  end

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    with {:ok, result} <- Accounts.refresh_session(refresh_token) do
      CommsObservability.execute([:auth, :success], %{count: 1}, %{tenant_id: result.tenant.id})
      json(conn, Token.issue(result))
    else
      {:error, reason} = error ->
        CommsObservability.execute([:auth, :failure], %{count: 1}, %{reason: reason})
        error
    end
  end

  def refresh(_conn, _params), do: {:error, :invalid_refresh_token}

  def delete(conn, _params) do
    subject = conn.assigns.current_subject

    with :ok <- Accounts.revoke_session(subject.session_id, subject.user_id) do
      CommsWeb.Endpoint.broadcast("session_socket:#{subject.session_id}", "disconnect", %{})
      send_resp(conn, :no_content, "")
    end
  end
end
