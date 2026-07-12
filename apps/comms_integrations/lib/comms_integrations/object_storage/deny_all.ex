defmodule CommsIntegrations.ObjectStorage.DenyAll do
  @behaviour CommsIntegrations.ObjectStorage
  @impl true
  def sign_upload(_request), do: {:error, :object_storage_adapter_not_configured}
end
