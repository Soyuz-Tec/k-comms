defmodule CommsWeb.CalendarController do
  use CommsWeb, :controller
  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.CalendarSync.CallbackCommand
  alias CommsWeb.CalendarPresenter
  plug(CommsWeb.Plugs.RequireSecureTransport)
  plug(:private_response)

  plug(
    CommsWeb.Plugs.RequireSameOriginJSON
    when action in [:authorize, :unlink, :create_export, :resolve_export]
  )

  def connections(conn, _params) do
    with {:ok, result} <- AudioCalls.list_calendar_connections(conn.assigns.current_subject),
         do:
           json(conn, %{
             data: Enum.map(result.connections, &CalendarPresenter.connection/1),
             meta: CalendarPresenter.metadata(result)
           })
  end

  def authorize(conn, %{"provider" => provider} = params) do
    with {:ok, provider} <- provider(provider),
         {:ok, result} <-
           AudioCalls.begin_calendar_authorization(provider, params, conn.assigns.current_subject) do
      conn
      |> put_resp_cookie(cookie(provider), result.browser_binding, cookie_options(provider))
      |> json(%{
        data: %{
          provider: provider,
          authorization_url: result.authorization_url,
          expires_at: CalendarPresenter.instant(result.expires_at)
        }
      })
    end
  end

  def callback(conn, %{"provider" => name} = params) do
    conn = fetch_cookies(conn)

    result =
      with {:ok, provider} <- provider(name) do
        AudioCalls.complete_calendar_authorization(%CallbackCommand{
          provider: provider,
          state: params["state"],
          code: params["code"],
          browser_binding: conn.cookies[cookie(provider)]
        })
      end

    conn =
      case provider(name) do
        {:ok, provider} -> delete_resp_cookie(conn, cookie(provider), cookie_options(provider))
        _ -> conn
      end

    status = if match?({:ok, _}, result), do: "connected", else: "rejected"

    conn
    |> put_status(:see_other)
    |> redirect(to: "/app/you?section=calendar&calendar_result=" <> status)
  end

  def unlink(conn, %{"connection_id" => id} = params) do
    with {:ok, result} <-
           AudioCalls.unlink_calendar_connection(id, params, conn.assigns.current_subject),
         do: json(conn, %{data: CalendarPresenter.connection(result)})
  end

  def exports(conn, params) do
    with {:ok, result} <- AudioCalls.list_calendar_exports(conn.assigns.current_subject, params),
         do:
           json(conn, %{
             data: Enum.map(result.exports, &CalendarPresenter.export/1),
             meta: %{truncated: result.truncated}
           })
  end

  def create_export(conn, params) do
    with {:ok, result} <- AudioCalls.create_calendar_export(params, conn.assigns.current_subject),
         do: conn |> put_status(:created) |> json(%{data: CalendarPresenter.export(result)})
  end

  def resolve_export(conn, %{"export_id" => id} = params) do
    with {:ok, result} <-
           AudioCalls.resolve_calendar_export(id, params, conn.assigns.current_subject),
         do: json(conn, %{data: CalendarPresenter.export(result)})
  end

  defp provider("google"), do: {:ok, :google}
  defp provider("microsoft"), do: {:ok, :microsoft}
  defp provider(_), do: {:error, :invalid_calendar_provider}
  defp cookie(provider), do: "k_comms_calendar_" <> Atom.to_string(provider)

  defp cookie_options(provider),
    do: [
      secure: true,
      http_only: true,
      same_site: "Lax",
      max_age: 300,
      path: "/api/v1/calendar/oauth/" <> Atom.to_string(provider) <> "/callback"
    ]

  defp private_response(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("pragma", "no-cache")
      |> put_resp_header("referrer-policy", "no-referrer")
end
