defmodule CommsWeb.Plugs.Authenticate do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id = conn.assigns[:request_id] || List.first(get_resp_header(conn, "x-request-id"))

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, context} <- CommsWeb.Token.verify(token, request_id) do
      conn
      |> assign(:current_subject, context.subject)
      |> assign(:current_session, context.session)
      |> assign(:current_user, context.user)
      |> assign(:current_tenant, context.tenant)
      |> assign(:current_device, context.device)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: %{code: "unauthenticated", detail: "A valid access token is required"}
          })
        )
        |> halt()
    end
  end
end
