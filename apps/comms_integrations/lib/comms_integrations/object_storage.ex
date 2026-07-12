defmodule CommsIntegrations.ObjectStorage do
  @callback presign_upload(map()) :: {:ok, map()} | {:error, term()}
  @callback presign_download(map()) :: {:ok, map()} | {:error, term()}
  @callback verify_upload(map()) :: :ok | {:error, term()}

  def presign_upload(request), do: adapter().presign_upload(request)
  def presign_download(request), do: adapter().presign_download(request)
  def verify_upload(request), do: adapter().verify_upload(request)

  # Compatibility for callers built against the executable bootstrap API.
  def sign_upload(request), do: presign_upload(request)

  defp adapter do
    Application.get_env(
      :comms_integrations,
      :object_storage_adapter,
      CommsIntegrations.ObjectStorage.DenyAll
    )
  end
end
