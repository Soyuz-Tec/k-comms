defmodule CommsIntegrations.ObjectStorage.S3.RestoreVerifierIntegrationTest do
  use ExUnit.Case, async: false

  import CommsIntegrations.ObjectStorageTestSupport

  @moduletag :integration
  @moduletag :object_storage

  test "S3 restore verification streams the current version and fails closed on changed bytes" do
    previous = Application.get_env(:comms_integrations, :s3)
    tenant_id = "restore-tenant-#{System.unique_integer([:positive, :monotonic])}"
    object_key = "#{tenant_id}/restore-#{System.unique_integer([:positive])}/evidence.txt"

    Application.put_env(:comms_integrations, :s3, s3_integration_config())

    on_exit(fn -> restore_env(:s3, previous) end)

    body = "portable-restored-content"
    checksum = sha256(body)

    original =
      attachment(%{
        tenant_id: tenant_id,
        object_key: object_key,
        content_type: "text/plain",
        byte_size: byte_size(body),
        checksum_sha256: checksum
      })

    assert :ok = upload(original, body)
    assert {:ok, original_identity} = CommsIntegrations.ObjectStorage.S3.verify_upload(original)

    assert :ok = upload(original, body)

    restored =
      original
      |> Map.merge(original_identity)
      |> Map.put(:verified_checksum_sha256, checksum)

    assert {:ok, restored_identity} =
             CommsIntegrations.ObjectStorage.S3.verify_restored_object(restored)

    assert restored_identity.object_version_id != original_identity.object_version_id
    assert restored_identity.verified_checksum_sha256 == checksum
    assert restored_identity.etag_verification == :matched

    opaque_etag = %{restored | object_etag: "\"provider-opaque-etag\""}

    assert {:ok, %{etag_verification: :not_trustworthy}} =
             CommsIntegrations.ObjectStorage.S3.verify_restored_object(opaque_etag)

    changed_body = String.duplicate("x", byte_size(body))
    changed = %{original | checksum_sha256: sha256(changed_body)}
    assert :ok = upload(changed, changed_body)

    assert {:error, :object_checksum_mismatch} =
             CommsIntegrations.ObjectStorage.S3.verify_restored_object(opaque_etag)
  end
end
