defmodule CommsIntegrations.ObjectStorageTest do
  use ExUnit.Case, async: false

  alias CommsCore.Attachments.Attachment

  test "memory adapter returns bounded upload and download intents" do
    attachment = %Attachment{
      tenant_id: "tenant",
      object_key: "tenant/file name.txt",
      content_type: "text/plain",
      checksum_sha256: String.duplicate("a", 64),
      object_version_id: "memory-v1"
    }

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
  end

  test "S3 adapter emits a SigV4 URL without exposing its secret" do
    previous = Application.get_env(:comms_integrations, :s3)

    Application.put_env(:comms_integrations, :s3,
      scheme: "https",
      host: "objects.example.test",
      port: 443,
      bucket: "k-comms",
      region: "us-east-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key",
      expires_in: 600
    )

    on_exit(fn -> restore_env(:s3, previous) end)

    checksum = String.duplicate("a", 64)

    attachment = %Attachment{
      tenant_id: "tenant",
      object_key: "tenant/message.txt",
      content_type: "text/plain",
      checksum_sha256: checksum,
      object_version_id: "version-1"
    }

    assert {:ok,
            %{
              method: "PUT",
              url: url,
              approved_origin: approved_origin,
              expires_in: 600,
              headers: headers
            }} =
             CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)

    assert url =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
    assert url =~ "X-Amz-Signature="
    refute url =~ "secret-key"
    assert URI.parse(url).userinfo == nil
    assert approved_origin == "https://objects.example.test"
    assert URI.parse(url).scheme <> "://" <> URI.parse(url).host == approved_origin

    assert headers == %{
             "content-type" => "text/plain",
             "x-amz-checksum-sha256" => Base.encode64(:binary.copy(<<0xAA>>, 32)),
             "x-amz-meta-sha256" => checksum
           }

    signed_headers = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert signed_headers["X-Amz-SignedHeaders"] ==
             "content-type;host;x-amz-checksum-sha256;x-amz-meta-sha256"

    assert {:ok, %{url: download_url}} =
             CommsIntegrations.ObjectStorage.S3.presign_download(attachment)

    assert URI.decode_query(URI.parse(download_url).query)["versionId"] == "version-1"
    assert URI.parse(download_url).userinfo == nil

    assert {:error, :object_version_unavailable} =
             CommsIntegrations.ObjectStorage.S3.delete_object(%{
               tenant_id: "tenant",
               object_key: "tenant/message.txt"
             })
  end

  test "HTTP public object-store origins are rejected unless explicitly local-development only" do
    previous_s3 = Application.get_env(:comms_integrations, :s3)

    previous_allow =
      Application.get_env(:comms_integrations, :allow_insecure_local_object_storage)

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

    on_exit(fn ->
      restore_env(:s3, previous_s3)
      restore_env(:allow_insecure_local_object_storage, previous_allow)
    end)

    attachment = %Attachment{
      tenant_id: "tenant",
      object_key: "tenant/file.txt",
      content_type: "text/plain",
      checksum_sha256: String.duplicate("a", 64)
    }

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

  test "object deletion rejects cross-tenant and unsafe object keys before reaching an adapter" do
    previous = Application.get_env(:comms_integrations, :object_storage_adapter)

    Application.put_env(
      :comms_integrations,
      :object_storage_adapter,
      CommsIntegrations.ObjectStorage.Memory
    )

    on_exit(fn -> restore_env(:object_storage_adapter, previous) end)

    assert {:error, :object_tenant_mismatch} =
             CommsIntegrations.ObjectStorage.delete_object(%{
               tenant_id: "tenant-a",
               object_key: "tenant-b/file.txt"
             })

    for key <- ["tenant-a/../file.txt", "tenant-a/path\\file.txt", "tenant-a/path//file.txt"] do
      assert {:error, :invalid_object_key} =
               CommsIntegrations.ObjectStorage.delete_object(%{
                 tenant_id: "tenant-a",
                 object_key: key
               })
    end
  end

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

  test "version-bound S3 downloads remain on the scanned object after the key is overwritten" do
    previous = Application.get_env(:comms_integrations, :s3)
    tenant_id = "tenant-#{System.unique_integer([:positive, :monotonic])}"
    object_key = "#{tenant_id}/object-#{System.unique_integer([:positive])}/evidence.txt"

    Application.put_env(:comms_integrations, :s3, s3_integration_config())

    on_exit(fn -> restore_env(:s3, previous) end)

    clean_body = "known-clean-content"
    clean_checksum = sha256(clean_body)

    clean = %Attachment{
      tenant_id: tenant_id,
      object_key: object_key,
      content_type: "text/plain",
      byte_size: byte_size(clean_body),
      checksum_sha256: clean_checksum
    }

    assert :ok = upload(clean, clean_body)
    assert {:ok, identity} = CommsIntegrations.ObjectStorage.S3.verify_upload(clean)

    replacement_body = "malicious-replaced!"

    replacement = %{
      clean
      | byte_size: byte_size(replacement_body),
        checksum_sha256: sha256(replacement_body)
    }

    assert :ok = upload(replacement, replacement_body)

    versioned = struct(clean, identity)
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

  test "S3 restore verification streams the current version and fails closed on changed bytes" do
    previous = Application.get_env(:comms_integrations, :s3)
    tenant_id = "restore-tenant-#{System.unique_integer([:positive, :monotonic])}"
    object_key = "#{tenant_id}/restore-#{System.unique_integer([:positive])}/evidence.txt"

    Application.put_env(:comms_integrations, :s3, s3_integration_config())

    on_exit(fn -> restore_env(:s3, previous) end)

    body = "portable-restored-content"
    checksum = sha256(body)

    original = %Attachment{
      tenant_id: tenant_id,
      object_key: object_key,
      content_type: "text/plain",
      byte_size: byte_size(body),
      checksum_sha256: checksum
    }

    assert :ok = upload(original, body)
    assert {:ok, original_identity} = CommsIntegrations.ObjectStorage.S3.verify_upload(original)

    # A portable mirror restore writes the same bytes as a new current version.
    assert :ok = upload(original, body)

    restored =
      original
      |> struct(original_identity)
      |> Map.put(:verified_checksum_sha256, checksum)

    assert {:ok, restored_identity} =
             CommsIntegrations.ObjectStorage.S3.verify_restored_object(restored)

    assert restored_identity.object_version_id != original_identity.object_version_id
    assert restored_identity.verified_checksum_sha256 == checksum
    assert restored_identity.etag_verification == :matched

    # Opaque provider ETags are not treated as content evidence; the streamed
    # SHA-256 remains authoritative for the remap decision.
    opaque_etag = %{restored | object_etag: "\"provider-opaque-etag\""}

    assert {:ok, %{etag_verification: :not_trustworthy}} =
             CommsIntegrations.ObjectStorage.S3.verify_restored_object(opaque_etag)

    changed_body = String.duplicate("x", byte_size(body))
    changed = %{original | checksum_sha256: sha256(changed_body)}
    assert :ok = upload(changed, changed_body)

    assert {:error, :object_checksum_mismatch} =
             CommsIntegrations.ObjectStorage.S3.verify_restored_object(opaque_etag)
  end

  defp upload(attachment, body) do
    with {:ok, descriptor} <- CommsIntegrations.ObjectStorage.S3.presign_upload(attachment),
         request <- Finch.build(:put, descriptor.url, Map.to_list(descriptor.headers), body),
         {:ok, %Finch.Response{status: status}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch) do
      :ok
    end
  end

  defp s3_integration_config do
    host = System.get_env("K_COMMS_TEST_S3_HOST", "minio")
    port = System.get_env("K_COMMS_TEST_S3_PORT", "9000") |> String.to_integer()

    [
      scheme: "http",
      host: host,
      port: port,
      internal_scheme: "http",
      internal_host: host,
      internal_port: port,
      bucket: System.get_env("K_COMMS_TEST_S3_BUCKET", "k-comms-dev"),
      region: "us-east-1",
      access_key_id: System.get_env("K_COMMS_TEST_S3_ACCESS_KEY_ID", "kcomms"),
      secret_access_key:
        System.get_env("K_COMMS_TEST_S3_SECRET_ACCESS_KEY", "change-this-local-password"),
      expires_in: 600
    ]
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp restore_env(key, nil), do: Application.delete_env(:comms_integrations, key)
  defp restore_env(key, value), do: Application.put_env(:comms_integrations, key, value)
end
