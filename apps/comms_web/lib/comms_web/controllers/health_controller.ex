defmodule CommsWeb.HealthController do
  use CommsWeb, :controller

  alias CommsCore.Repo

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    database = database_check()
    runtime = runtime_check()
    storage = storage_check()
    ready? = database.status == "ok" and runtime.status == "ok"

    conn
    |> put_status(if(ready?, do: :ok, else: :service_unavailable))
    |> json(%{
      status: if(ready?, do: "ready", else: "not_ready"),
      checks: %{database: database, runtime: runtime, object_storage: storage}
    })
  end

  defp database_check do
    started = System.monotonic_time()

    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: 3_000) do
      {:ok, _} ->
        %{status: "ok", latency_ms: elapsed_milliseconds(started)}

      {:error, _reason} ->
        %{status: "error"}
    end
  end

  defp runtime_check do
    role = System.get_env("K_COMMS_ROLE", "all")

    if role in ["all", "worker"] and is_nil(Oban.whereis(Oban)) do
      %{status: "error", role: role, jobs: "unavailable"}
    else
      %{status: "ok", role: role, jobs: if(role == "edge", do: "disabled", else: "ready")}
    end
  end

  defp storage_check do
    adapter =
      Application.get_env(:comms_integrations, :object_storage_adapter) ||
        CommsIntegrations.ObjectStorage.DenyAll

    status =
      if adapter == CommsIntegrations.ObjectStorage.DenyAll,
        do: "unavailable",
        else: "configured"

    # Object storage is deliberately a degraded capability rather than a
    # readiness dependency: a provider outage must not stop durable text
    # messaging. The protected operations snapshot performs the deeper check.
    %{status: status}
  end

  defp elapsed_milliseconds(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
    |> Float.round(3)
  end
end
