defmodule CommsIntegrations.ObjectStorage.S3.VersionPurgerIntegrationTest do
  use ExUnit.Case, async: false

  import CommsIntegrations.ObjectStorageTestSupport

  @moduletag :integration
  @moduletag :object_storage

  test "S3 deletion fails closed on missing configuration and provider failure" do
    previous = Application.get_env(:comms_integrations, :s3)

    request = %{
      tenant_id: "tenant",
      object_key: "tenant/file.txt",
      object_version_id: "version-1"
    }

    on_exit(fn -> restore_env(:s3, previous) end)

    Application.put_env(:comms_integrations, :s3, [])

    assert {:error, {:missing_s3_config, :scheme}} =
             CommsIntegrations.ObjectStorage.S3.delete_object(request)

    Application.put_env(:comms_integrations, :s3,
      scheme: "https",
      host: "objects.example.test",
      port: 443,
      internal_scheme: "http",
      internal_host: "127.0.0.1",
      internal_port: 1,
      bucket: "k-comms",
      region: "us-east-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key",
      expires_in: 60
    )

    assert {:error, _reason} = CommsIntegrations.ObjectStorage.S3.delete_object(request)
  end

  @tag :slow
  test "S3 abandonment purge deletes and verifies every version under the exact key" do
    previous = Application.get_env(:comms_integrations, :s3)
    tenant_id = "purge-tenant-#{System.unique_integer([:positive, :monotonic])}"
    object_key = "#{tenant_id}/purge-#{System.unique_integer([:positive])}/evidence.txt"

    Application.put_env(:comms_integrations, :s3, s3_integration_config())

    on_exit(fn -> restore_env(:s3, previous) end)

    versions =
      for body <- ["first-version", "second-version", "third-version"] do
        candidate =
          attachment(%{
            tenant_id: tenant_id,
            object_key: object_key,
            content_type: "text/plain",
            byte_size: byte_size(body),
            checksum_sha256: sha256(body)
          })

        assert :ok = upload(candidate, body)
        assert {:ok, identity} = CommsIntegrations.ObjectStorage.S3.verify_upload(candidate)
        identity
      end

    assert {:ok,
            %{
              deleted_versions: deleted_versions,
              verified_empty?: true
            }} =
             CommsIntegrations.ObjectStorage.S3.purge_object_versions(%{
               tenant_id: tenant_id,
               object_key: object_key
             })

    assert deleted_versions >= 3

    for identity <- versions do
      versioned =
        attachment(%{
          tenant_id: tenant_id,
          object_key: object_key,
          object_version_id: identity.object_version_id
        })

      assert {:ok, descriptor} =
               CommsIntegrations.ObjectStorage.S3.presign_download(versioned)

      request = Finch.build(:get, descriptor.url, Map.to_list(descriptor.headers))
      assert {:ok, %Finch.Response{status: 404}} = Finch.request(request, CommsIntegrations.Finch)
    end

    assert {:ok, %{deleted_versions: 0, deleted_markers: 0, verified_empty?: true}} =
             CommsIntegrations.ObjectStorage.S3.purge_object_versions(%{
               tenant_id: tenant_id,
               object_key: object_key
             })
  end
end
