defmodule CommsWeb.Plugs.RequireSameOriginJSON do
  @moduledoc """
  Restricts browser-facing instant-room mutations to trusted JSON origins.

  JSON prevents form-post CSRF and the Origin check prevents an allowed browser
  credential from being replayed by an unrelated site. Explicit CORS origins
  remain supported for the local Vite development server.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with :ok <- require_json(conn),
         :ok <- require_trusted_origin(conn) do
      conn
    else
      {:error, code, detail, status} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{error: %{code: code, detail: detail}}))
        |> halt()
    end
  end

  defp require_json(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        case Plug.Conn.Utils.media_type(content_type) do
          {:ok, "application", "json", _params} ->
            :ok

          _ ->
            unsupported_content_type()
        end

      _ ->
        unsupported_content_type()
    end
  end

  defp require_trusted_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin] ->
        if origin in trusted_origins(conn) do
          :ok
        else
          {:error, "untrusted_origin", "The request origin is not permitted", :forbidden}
        end

      _ ->
        {:error, "origin_required", "A trusted browser origin is required", :forbidden}
    end
  end

  defp trusted_origins(_conn) do
    configured =
      case Application.get_env(:comms_web, :cors_origins, []) do
        origins when is_list(origins) -> origins
        _invalid -> []
      end

    public_app_origin =
      case Application.get_env(:comms_core, :public_app_url) do
        origin when is_binary(origin) -> origin
        _invalid -> nil
      end

    [public_app_origin | configured]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim_trailing(&1, "/"))
    |> Enum.uniq()
  end

  defp unsupported_content_type do
    {:error, "unsupported_content_type", "Content-Type must be application/json",
     :unsupported_media_type}
  end
end
