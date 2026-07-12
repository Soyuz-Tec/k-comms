defmodule CommsWeb.Plugs.AuthenticateMetrics do
  @moduledoc "Authenticates Prometheus-compatible metric scrapers."

  import Plug.Conn
  alias Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    configured = Application.get_env(:comms_web, :metrics_bearer_token)

    allow_unauthenticated? =
      Application.get_env(:comms_web, :metrics_allow_unauthenticated, false)

    if allow_unauthenticated? or valid_token?(conn, configured) do
      conn
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Bearer realm="k-comms-metrics"))
      |> put_status(:unauthorized)
      |> Controller.json(%{error: %{code: "unauthorized", message: "authentication required"}})
      |> halt()
    end
  end

  defp valid_token?(conn, configured)
       when is_binary(configured) and byte_size(configured) >= 32 do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> provided] when byte_size(provided) == byte_size(configured) ->
        Plug.Crypto.secure_compare(provided, configured)

      _ ->
        false
    end
  end

  defp valid_token?(_conn, _configured), do: false
end
