defmodule CommsIntegrations.MeetingArtifacts.S3StorageTest do
  use ExUnit.Case, async: false

  alias CommsCore.AudioCalls.ArtifactStorageObject
  alias CommsIntegrations.MeetingArtifacts.S3Storage

  @checksum :crypto.hash(:sha256, "synthetic-artifact") |> Base.encode16(case: :lower)

  setup do
    values = %{
      object_storage_adapter: CommsIntegrations.ObjectStorage.S3,
      s3: [
        scheme: "https",
        host: "files.example.test",
        port: 443,
        bucket: "approved-bucket",
        region: "us-east-1",
        access_key_id: "synthetic-access-key",
        secret_access_key: "synthetic-storage-secret"
      ]
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_integrations, key, value)
        {key, :error} -> Application.delete_env(:comms_integrations, key)
      end)
    end)
  end

  test "first verification captures a checksum and version then pins a second HEAD" do
    parent = self()

    requester = fn request ->
      assert request.method == "HEAD"
      assert request.host == "files.example.test"
      assert request.path == "/approved-bucket/tenant/meeting-artifacts/call/artifact.mp4"
      assert {"x-amz-checksum-mode", "ENABLED"} in request.headers
      send(parent, {:head_query, URI.decode_query(request.query)})
      {:ok, %{status: 200, headers: headers()}}
    end

    assert {:ok,
            %ArtifactStorageObject{
              object_version_id: "version-exact",
              checksum_sha256: @checksum,
              verified_checksum_sha256: @checksum,
              object_etag: "etag-exact"
            }} = S3Storage.verify(object(), requester)

    assert_receive {:head_query, first}
    refute Map.has_key?(first, "versionId")
    assert_receive {:head_query, %{"versionId" => "version-exact"}}
    refute_receive {:head_query, _}
  end

  test "existing pins require an exact version, size and full-object checksum" do
    pinned = %{object() | object_version_id: "version-exact", checksum_sha256: @checksum}

    assert {:ok, _} =
             S3Storage.verify(pinned, fn request ->
               assert URI.decode_query(request.query)["versionId"] == "version-exact"
               {:ok, %{status: 200, headers: headers()}}
             end)

    for {header, value} <- [
          {"x-amz-version-id", "version-other"},
          {"content-length", "101"},
          {"x-amz-checksum-type", "COMPOSITE"},
          {"x-amz-server-side-encryption", ""}
        ] do
      changed = List.keystore(headers(), header, 0, {header, value})

      assert {:error, _} =
               S3Storage.verify(pinned, fn _ -> {:ok, %{status: 200, headers: changed}} end)
    end
  end

  test "metadata alone cannot certify bytes and latest-version races fail verification" do
    metadata_only = Enum.reject(headers(), fn {key, _} -> key == "x-amz-checksum-sha256" end)

    assert S3Storage.verify(object(), fn _ -> {:ok, %{status: 200, headers: metadata_only}} end) ==
             {:error, :artifact_object_checksum_unavailable}

    requester = fn request ->
      observed =
        if URI.decode_query(request.query)["versionId"],
          do:
            List.keystore(headers(), "x-amz-version-id", 0, {"x-amz-version-id", "version-other"}),
          else: headers()

      {:ok, %{status: 200, headers: observed}}
    end

    assert {:error, :artifact_object_verification_failed} = S3Storage.verify(object(), requester)
  end

  test "download requires verified pins and always signs the approved bucket version" do
    assert {:error, :object_version_unavailable} = S3Storage.download(object())

    pinned = %{
      object()
      | object_version_id: "version-exact",
        checksum_sha256: @checksum,
        verified_checksum_sha256: @checksum
    }

    assert {:ok, descriptor} = S3Storage.download(pinned)
    uri = URI.parse(descriptor.url)
    assert uri.host == "files.example.test"
    assert uri.path == "/approved-bucket/tenant/meeting-artifacts/call/artifact.mp4"
    query = URI.decode_query(uri.query)
    assert query["versionId"] == "version-exact"
    assert query["response-content-disposition"] == "attachment"
    assert descriptor.expires_in <= 120
  end

  test "unapproved destinations and tenant mismatches cannot invoke the transport" do
    never = fn _ -> flunk("unapproved storage transport") end

    assert {:error, :invalid_artifact_storage_object} =
             S3Storage.verify(%{object() | tenant_id: "other-tenant"}, never)

    assert {:error, :invalid_artifact_storage_object} =
             S3Storage.verify(
               %{object() | object_key: "tenant/meeting-artifacts/../artifact.mp4"},
               never
             )

    assert {:error, :invalid_artifact_storage_object} =
             S3Storage.verify(Map.from_struct(object()), never)

    Application.put_env(
      :comms_integrations,
      :object_storage_adapter,
      CommsIntegrations.ObjectStorage.Memory
    )

    refute S3Storage.configured?()
    assert {:error, :artifact_storage_unavailable} = S3Storage.verify(object(), never)
  end

  test "deletion purges all versions only at the exact unique key and requires verified absence" do
    pinned = %{object() | object_version_id: "version-exact"}

    assert S3Storage.delete(pinned, fn request ->
             assert request == %{tenant_id: "tenant", object_key: object().object_key}
             {:ok, %{deleted_versions: 2, deleted_markers: 1, verified_empty?: true}}
           end) == :ok

    assert S3Storage.delete(pinned, fn _ ->
             {:ok, %{deleted_versions: 1, deleted_markers: 0, verified_empty?: false}}
           end) == {:error, :artifact_object_deletion_not_verified}

    assert S3Storage.delete(object(), fn request ->
             assert request == %{tenant_id: "tenant", object_key: object().object_key}
             {:ok, %{deleted_versions: 0, deleted_markers: 0, verified_empty?: true}}
           end) == :ok
  end

  defp object do
    %ArtifactStorageObject{
      tenant_id: "tenant",
      object_key: "tenant/meeting-artifacts/call/artifact.mp4",
      content_type: "video/mp4",
      byte_size: 100
    }
  end

  defp headers do
    [
      {"content-length", "100"},
      {"x-amz-version-id", "version-exact"},
      {"x-amz-checksum-sha256",
       CommsIntegrations.ObjectStorage.S3.ObjectMetadata.checksum_base64(@checksum)},
      {"x-amz-meta-sha256", @checksum},
      {"x-amz-server-side-encryption", "AES256"},
      {"etag", "etag-exact"}
    ]
  end
end
