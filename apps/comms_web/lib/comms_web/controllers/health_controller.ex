defmodule CommsWeb.HealthController do
  use CommsWeb, :controller
  alias CommsCore.Repo
  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> json(conn, %{status: "ready"})
      {:error, _} -> conn |> put_status(:service_unavailable) |> json(%{status: "not_ready"})
    end
  end
end
