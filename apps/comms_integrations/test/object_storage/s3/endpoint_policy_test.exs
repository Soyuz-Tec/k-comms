defmodule CommsIntegrations.ObjectStorage.S3.EndpointPolicyTest do
  use ExUnit.Case, async: false

  import CommsIntegrations.ObjectStorageTestSupport

  @moduletag :unit
  @moduletag :object_storage

  setup do
    previous_s3 = Application.get_env(:comms_integrations, :s3)

    previous_allow =
      Application.get_env(:comms_integrations, :allow_insecure_local_object_storage)

    previous_host = Application.get_env(:comms_integrations, :insecure_local_object_storage_host)

    on_exit(fn ->
      restore_env(:s3, previous_s3)
      restore_env(:allow_insecure_local_object_storage, previous_allow)
      restore_env(:insecure_local_object_storage_host, previous_host)
    end)

    :ok
  end

  test "HTTP public object-store origins are rejected unless explicitly local-development only" do
    Application.put_env(:comms_integrations, :s3,
      scheme: "http",
      host: "localhost",
      port: 9000,
      bucket: "k-comms",
      region: "us-east-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key"
    )

    Application.put_env(:comms_integrations, :allow_insecure_local_object_storage, false)

    attachment =
      attachment(%{
        tenant_id: "tenant",
        object_key: "tenant/file.txt",
        content_type: "text/plain",
        checksum_sha256: String.duplicate("a", 64)
      })

    assert {:error, :insecure_public_object_storage_endpoint} =
             CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)

    Application.put_env(:comms_integrations, :allow_insecure_local_object_storage, true)

    assert {:ok,
            %{
              approved_origin: "http://localhost:9000",
              development_http: true,
              url: url
            }} = CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)

    assert URI.parse(url).userinfo == nil
  end

  test "HTTP internal object-store origins use the same explicit local-only gate" do
    Application.put_env(:comms_integrations, :s3,
      scheme: "https",
      host: "objects.example.test",
      port: 443,
      internal_scheme: "http",
      internal_host: "objects.internal",
      internal_port: 9000,
      bucket: "k-comms",
      region: "us-east-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key"
    )

    Application.put_env(:comms_integrations, :allow_insecure_local_object_storage, false)

    assert %{
             status: :unavailable,
             reason: :insecure_internal_object_storage_endpoint
           } = CommsIntegrations.ObjectStorage.S3.status()

    assert {:error, :insecure_internal_object_storage_endpoint} =
             CommsIntegrations.ObjectStorage.S3.delete_object(%{
               tenant_id: "tenant",
               object_key: "tenant/file.txt",
               object_version_id: "version-1",
               storage_etag: "etag-1"
             })
  end

  test "HTTP public object-store origin permits only the exact selected RFC1918 host" do
    attachment =
      attachment(%{
        tenant_id: "tenant",
        object_key: "tenant/file.txt",
        content_type: "text/plain",
        checksum_sha256: String.duplicate("a", 64)
      })

    Application.put_env(:comms_integrations, :allow_insecure_local_object_storage, true)
    Application.put_env(:comms_integrations, :insecure_local_object_storage_host, "192.168.1.177")

    Application.put_env(:comms_integrations, :s3,
      scheme: "http",
      host: "192.168.1.177",
      port: 5900,
      bucket: "k-comms",
      region: "us-east-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key"
    )

    assert {:ok,
            %{
              approved_origin: "http://192.168.1.177:5900",
              development_http: true
            }} = CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)

    for other_private_host <- ["192.168.1.178", "10.0.0.1", "172.16.0.1"] do
      Application.put_env(
        :comms_integrations,
        :s3,
        scheme: "http",
        host: other_private_host,
        port: 5900,
        bucket: "k-comms",
        region: "us-east-1",
        access_key_id: "access-key",
        secret_access_key: "secret-key"
      )

      assert {:error, :insecure_public_object_storage_endpoint} =
               CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)
    end

    Application.put_env(:comms_integrations, :allow_insecure_local_object_storage, false)

    Application.put_env(:comms_integrations, :s3,
      scheme: "http",
      host: "192.168.1.177",
      port: 5900,
      bucket: "k-comms",
      region: "us-east-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key"
    )

    assert {:error, :insecure_public_object_storage_endpoint} =
             CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)
  end

  test "HTTP object-store selector rejects public reserved wildcard and malformed hosts" do
    attachment =
      attachment(%{
        tenant_id: "tenant",
        object_key: "tenant/file.txt",
        content_type: "text/plain",
        checksum_sha256: String.duplicate("a", 64)
      })

    Application.put_env(:comms_integrations, :allow_insecure_local_object_storage, true)

    for invalid_host <- [
          "0.0.0.0",
          "8.8.8.8",
          "100.64.0.10",
          "169.254.0.10",
          "192.0.2.10",
          "192.168.001.177",
          "objects.internal"
        ] do
      Application.put_env(
        :comms_integrations,
        :insecure_local_object_storage_host,
        invalid_host
      )

      Application.put_env(
        :comms_integrations,
        :s3,
        scheme: "http",
        host: invalid_host,
        port: 5900,
        bucket: "k-comms",
        region: "us-east-1",
        access_key_id: "access-key",
        secret_access_key: "secret-key"
      )

      assert {:error, :insecure_public_object_storage_endpoint} =
               CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)
    end
  end
end
