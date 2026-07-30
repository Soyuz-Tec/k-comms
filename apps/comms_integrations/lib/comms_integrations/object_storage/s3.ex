defmodule CommsIntegrations.ObjectStorage.S3 do
  @behaviour CommsIntegrations.ObjectStorage

  alias CommsIntegrations.ObjectStorage.S3.{
    EndpointPolicy,
    PresignedOperations,
    RestoreVerifier,
    UploadVerifier,
    VersionPurger
  }

  @impl true
  defdelegate presign_upload(attachment), to: PresignedOperations

  @impl true
  defdelegate presign_download(attachment), to: PresignedOperations

  @impl true
  defdelegate presign_variant_upload(variant), to: PresignedOperations

  @impl true
  defdelegate presign_variant_download(variant), to: PresignedOperations

  @impl true
  defdelegate verify_variant_upload(variant), to: UploadVerifier

  @impl true
  defdelegate verify_upload(attachment), to: UploadVerifier

  @impl true
  defdelegate verify_restored_object(attachment), to: RestoreVerifier

  @impl true
  defdelegate delete_object(request), to: VersionPurger

  @impl true
  defdelegate purge_object_versions(request), to: VersionPurger

  @impl true
  def status, do: EndpointPolicy.status()
end
