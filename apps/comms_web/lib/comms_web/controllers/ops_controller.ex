defmodule CommsWeb.OpsController do
  use CommsWeb, :controller

  alias CommsCore.Operations
  alias CommsCore.PushSubscriptions
  alias CommsIntegrations.{Notifications, ObjectStorage, Scanner, Webhooks}

  def show(conn, _params) do
    with {:ok, snapshot} <- Operations.snapshot(conn.assigns.current_subject) do
      providers = provider_statuses(&tenant_provider_status/1)

      json(conn, %{data: Map.put(snapshot, :providers, providers)})
    end
  end

  def platform(conn, _params) do
    with {:ok, snapshot} <- Operations.platform_snapshot(conn.assigns.current_subject) do
      json(conn, %{
        data: Map.put(snapshot, :providers, provider_statuses(&platform_provider_status/1))
      })
    end
  end

  def retry(conn, %{"resource_type" => resource_type, "id" => id}) do
    with {:ok, resource} <-
           Operations.retry(resource_type, id, conn.assigns.current_subject) do
      conn
      |> put_status(:accepted)
      |> json(%{data: %{id: resource.id, resource_type: resource_type, status: resource.status}})
    end
  end

  def retry(_conn, _params), do: {:error, {:missing_fields, ["resource_type", "id"]}}

  defp provider_statuses(mapper) do
    %{
      notifications: mapper.(Notifications.status()),
      webhooks: mapper.(Webhooks.status()),
      attachment_scanner: mapper.(Scanner.status()),
      object_storage: mapper.(ObjectStorage.status()),
      browser_push: mapper.(PushSubscriptions.status())
    }
  end

  defp tenant_provider_status(%{status: status}), do: %{status: status}
  defp tenant_provider_status(_), do: %{status: :unavailable}

  defp platform_provider_status(status) when is_map(status) do
    Map.take(status, [:status, :adapter, :reason, :test_only, :missing])
  end

  defp platform_provider_status(_), do: %{status: :unavailable}
end
