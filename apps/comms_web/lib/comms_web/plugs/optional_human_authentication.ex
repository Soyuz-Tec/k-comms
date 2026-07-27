defmodule CommsWeb.Plugs.OptionalHumanAuthentication do
  @moduledoc """
  Authenticates a human bearer token when one is supplied.

  The absence of an Authorization header is the only anonymous case. Invalid,
  guest-scoped, service, malformed, or duplicate authorization values fail
  closed instead of silently degrading to anonymous access.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id = conn.assigns[:request_id] || List.first(get_resp_header(conn, "x-request-id"))

    case get_req_header(conn, "authorization") do
      [] ->
        assign(conn, :current_subject, nil)

      ["Bearer " <> token] ->
        authenticate(conn, token, request_id)

      _invalid_or_ambiguous ->
        reject(conn)
    end
  end

  defp authenticate(conn, token, request_id) do
    case CommsWeb.Token.verify(token, request_id) do
      {:ok, %{subject: subject, user: user} = context}
      when user.account_type in [:human, "human"] and
             subject.account_type in [:human, "human"] ->
        conn
        |> assign(:current_subject, context.subject)
        |> assign(:current_session, context.session)
        |> assign(:current_user, context.user)
        |> assign(:current_tenant, context.tenant)
        |> assign(:current_device, context.device)

      {:error, _reason} ->
        reject(conn)

      _non_human_or_malformed_context ->
        reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      :unauthorized,
      Jason.encode!(%{
        error: %{code: "unauthenticated", detail: "Authentication failed"}
      })
    )
    |> halt()
  end
end
