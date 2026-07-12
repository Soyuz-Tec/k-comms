defmodule CommsIntegrations.ObjectStorage do
  @callback sign_upload(map()) :: {:ok, map()} | {:error, term()}
  def sign_upload(request), do: adapter().sign_upload(request)
  defp adapter, do: Application.get_env(:comms_integrations, :object_storage_adapter, CommsIntegrations.ObjectStorage.DenyAll)
end
