defmodule CommsIntegrations.ObjectStorage.S3.VariantPresignsTest do
  use ExUnit.Case, async: false

  import CommsIntegrations.ObjectStorageTestSupport

  @moduletag :unit
  @moduletag :object_storage

  setup do
    previous = Application.get_env(:comms_integrations, :s3)

    Application.put_env(:comms_integrations, :s3,
      scheme: "https",
      host: "objects.example.test",
      port: 443,
      bucket: "bucket",
      region: "us-east-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key",
      expires_in: 900
    )

    on_exit(fn -> restore_env(:s3, previous) end)
    :ok
  end

  test "signs the variant content type so the store rejects any other" do
    assert {:ok, %{url: url, headers: headers}} =
             CommsIntegrations.ObjectStorage.S3.presign_variant_upload(variant())

    assert headers["content-type"] == "image/webp"
    assert headers["x-amz-server-side-encryption"] == "AES256"

    signed = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert signed["X-Amz-SignedHeaders"] =~ "content-type"
  end

  test "refuses to sign an upload for a type outside the allowlist" do
    for type <- ["image/svg+xml", "text/html", "application/octet-stream", nil] do
      assert {:error, :unsupported_variant_content_type} =
               CommsIntegrations.ObjectStorage.S3.presign_variant_upload(
                 variant(%{content_type: type})
               )
    end
  end

  test "serves a thumbnail inline under its pinned type" do
    assert {:ok, %{url: url}} =
             CommsIntegrations.ObjectStorage.S3.presign_variant_download(
               variant(%{object_version_id: "thumb-v1"})
             )

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["response-content-disposition"] == "inline"
    assert query["response-content-type"] == "image/webp"
    assert query["versionId"] == "thumb-v1"
  end

  test "refuses an inline download for a type outside the allowlist" do
    assert {:error, :unsupported_variant_content_type} =
             CommsIntegrations.ObjectStorage.S3.presign_variant_download(
               variant(%{content_type: "image/svg+xml", object_version_id: "thumb-v1"})
             )
  end

  test "refuses a download without a verified version" do
    assert {:error, :variant_version_unavailable} =
             CommsIntegrations.ObjectStorage.S3.presign_variant_download(variant())
  end

  test "refuses any variant operation without a key" do
    assert {:error, :variant_object_key_unavailable} =
             CommsIntegrations.ObjectStorage.S3.presign_variant_upload(
               variant(%{object_key: nil})
             )

    assert {:error, :variant_object_key_unavailable} =
             CommsIntegrations.ObjectStorage.S3.presign_variant_download(
               variant(%{object_key: nil})
             )
  end

  test "uses the short download lifetime for an inline variant" do
    assert {:ok, %{expires_in: 120}} =
             CommsIntegrations.ObjectStorage.S3.presign_variant_download(
               variant(%{object_version_id: "thumb-v1"})
             )
  end

  defp variant(attrs \\ %{}) do
    Map.merge(
      %{
        kind: :thumbnail,
        object_key: "tenant/attachment-id/thumbnail",
        content_type: "image/webp",
        byte_size: 4_096,
        checksum_sha256: String.duplicate("b", 64)
      },
      attrs
    )
  end
end
