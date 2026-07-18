defmodule CommsWeb.HealthController do
  use CommsWeb, :controller

  alias CommsCore.Operations

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
    case Operations.database_readiness() do
      {:ok, latency_ms} ->
        %{status: "ok", latency_ms: latency_ms}

      {:error, :unavailable} ->
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
end
