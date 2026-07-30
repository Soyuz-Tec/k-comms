defmodule CommsIntegrations.ObjectStorage.MemoryTest do
  use ExUnit.Case, async: true

  import CommsIntegrations.ObjectStorageTestSupport

  @moduletag :unit
  @moduletag :object_storage

  test "memory adapter returns bounded upload and download intents" do
    attachment =
      attachment(%{
        tenant_id: "tenant",
        object_key: "tenant/file name.txt",
        content_type: "text/plain",
        checksum_sha256: String.duplicate("a", 64),
        object_version_id: "memory-v1"
      })

    assert {:ok,
            %{
              method: "PUT",
              url: upload_url,
              approved_origin: "https://object-storage.test",
              development_http: false,
              expires_in: 900
            }} =
             CommsIntegrations.ObjectStorage.Memory.presign_upload(attachment)

    assert upload_url =~ "file%20name.txt"

    assert {:ok,
            %{
              method: "GET",
              url: download_url,
              approved_origin: "https://object-storage.test"
            }} =
             CommsIntegrations.ObjectStorage.Memory.presign_download(attachment)

    assert download_url == upload_url <> "?versionId=memory-v1"

    assert :ok =
             CommsIntegrations.ObjectStorage.Memory.delete_object(%{
               tenant_id: "tenant",
               object_key: "tenant/file name.txt",
               object_version_id: "memory-v1"
             })

    assert {:ok, %{deleted_versions: 0, deleted_markers: 0, verified_empty?: true}} =
             CommsIntegrations.ObjectStorage.Memory.purge_object_versions(%{
               tenant_id: "tenant",
               object_key: "tenant/file name.txt"
             })
  end
end
