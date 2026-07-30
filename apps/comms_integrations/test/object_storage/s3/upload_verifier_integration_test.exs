defmodule CommsIntegrations.ObjectStorage.S3.UploadVerifierIntegrationTest do
  use ExUnit.Case, async: false

  import CommsIntegrations.ObjectStorageTestSupport

  @moduletag :integration
  @moduletag :object_storage

  test "version-bound S3 downloads remain on the scanned object after the key is overwritten" do
    previous = Application.get_env(:comms_integrations, :s3)
    tenant_id = "tenant-#{System.unique_integer([:positive, :monotonic])}"
    object_key = "#{tenant_id}/object-#{System.unique_integer([:positive])}/evidence.txt"

    Application.put_env(:comms_integrations, :s3, s3_integration_config())

    on_exit(fn -> restore_env(:s3, previous) end)

    clean_body = "known-clean-content"
    clean_checksum = sha256(clean_body)

    clean =
      attachment(%{
        tenant_id: tenant_id,
        object_key: object_key,
        content_type: "text/plain",
        byte_size: byte_size(clean_body),
        checksum_sha256: clean_checksum
      })

    assert :ok = upload(clean, clean_body)
    assert {:ok, identity} = CommsIntegrations.ObjectStorage.S3.verify_upload(clean)

    replacement_body = "malicious-replaced!"

    replacement = %{
      clean
      | byte_size: byte_size(replacement_body),
        checksum_sha256: sha256(replacement_body)
    }

    assert :ok = upload(replacement, replacement_body)

    versioned = Map.merge(clean, identity)
    assert {:ok, descriptor} = CommsIntegrations.ObjectStorage.S3.presign_download(versioned)

    request = Finch.build(:get, descriptor.url, Map.to_list(descriptor.headers))

    assert {:ok, %Finch.Response{status: 200, body: ^clean_body}} =
             Finch.request(request, CommsIntegrations.Finch)

    assert :ok =
             CommsIntegrations.ObjectStorage.S3.delete_object(%{
               tenant_id: tenant_id,
               object_key: object_key,
               object_version_id: identity.object_version_id
             })
  end
end
