defmodule CommsWeb.Plugs.AuthenticateGuest do
  @moduledoc "Authenticates and scopes a guest request to its signed conversation admission."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id = conn.assigns[:request_id] || List.first(get_resp_header(conn, "x-request-id"))

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{context: context, access: access, claims: claims}} <-
           CommsWeb.GuestToken.verify(token, request_id),
         {:ok, guest_expires_at} <- effective_guest_expiry(context, access) do
      subject =
        Map.merge(context.subject, %{
          account_type: :guest,
          conversation_id: claims["conversation_id"],
          admission_id: claims["admission_id"],
          guest_conversation_id: claims["conversation_id"],
          guest_admission_id: claims["admission_id"],
          history_from_sequence: Map.get(access, :history_from_sequence),
          guest_history_from_sequence: Map.get(access, :history_from_sequence),
          guest_expires_at: guest_expires_at
        })

      conn
      |> assign(:current_subject, subject)
      |> assign(:current_session, context.session)
      |> assign(:current_user, context.user)
      |> assign(:current_tenant, context.tenant)
      |> assign(:current_device, context.device)
      |> assign(:current_guest_access, access)
      |> assign(:current_guest_claims, claims)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: %{code: "unauthenticated", detail: "A valid guest access token is required"}
          })
        )
        |> halt()
    end
  end

  defp effective_guest_expiry(context, access) do
    deadlines = [
      value(access, :expires_at),
      value(context.user, :guest_expires_at),
      value(context.session, :expires_at),
      value(context.session, :absolute_expires_at)
    ]

    if Enum.all?(deadlines, &match?(%DateTime{}, &1)) do
      expires_at =
        Enum.min_by(deadlines, fn deadline ->
          DateTime.to_unix(deadline, :microsecond)
        end)

      if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
        do: {:ok, expires_at},
        else: {:error, :guest_session_expired}
    else
      {:error, :invalid_guest_scope}
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil
end
