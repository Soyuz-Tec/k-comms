defmodule CommsWeb.Plugs.AuthenticateService do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id = conn.assigns[:request_id] || List.first(get_resp_header(conn, "x-request-id"))

    with ["Bearer " <> "kcsa_" <> _ = authorization] <- get_req_header(conn, "authorization"),
         token <- String.replace_prefix(authorization, "Bearer ", ""),
         {:ok, subject} <- CommsCore.ServiceAccounts.authenticate(token, request_id) do
      conn
      |> assign(:current_subject, subject)
      |> assign(:current_service_subject, subject)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: %{code: "unauthenticated", detail: "A valid service credential is required"}
          })
        )
        |> halt()
    end
  end
end
