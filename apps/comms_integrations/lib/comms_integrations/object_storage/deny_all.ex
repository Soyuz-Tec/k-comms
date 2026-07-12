defmodule CommsIntegrations.ObjectStorage.DenyAll do
  @behaviour CommsIntegrations.ObjectStorage
  @impl true
  def presign_upload(_request), do: {:error, :object_storage_adapter_not_configured}

  @impl true
  def presign_download(_request), do: {:error, :object_storage_adapter_not_configured}

  @impl true
  def verify_upload(_request), do: {:error, :object_storage_adapter_not_configured}
end
