defmodule CommsIntegrations.ObjectStorage.S3.PresignedOperationsTest do
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

  test "S3 adapter emits a SigV4 URL without exposing its secret" do
    checksum = String.duplicate("a", 64)

    attachment =
      attachment(%{
        tenant_id: "tenant",
        object_key: "tenant/message.txt",
        content_type: "text/plain",
        checksum_sha256: checksum,
        object_version_id: "version-1"
      })

    assert {:ok,
            %{
              method: "PUT",
              url: url,
              approved_origin: approved_origin,
              expires_in: 900,
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
             "x-amz-meta-sha256" => checksum,
             "x-amz-server-side-encryption" => "AES256"
           }

    signed_headers = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert signed_headers["X-Amz-SignedHeaders"] ==
             "content-type;host;x-amz-checksum-sha256;x-amz-meta-sha256;x-amz-server-side-encryption"

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

  test "forces an opaque content type and attachment disposition" do
    query = download_query(%{file_name: "notes.txt", content_type: "text/plain"})

    assert query["response-content-type"] == "application/octet-stream"
    assert query["response-content-disposition"] =~ "attachment"
  end

  test "signs both response overrides so neither can be stripped" do
    query = download_query(%{file_name: "notes.txt"})
    assert query["X-Amz-Signature"]

    tampered =
      query
      |> Map.delete("response-content-disposition")
      |> URI.encode_query()

    refute tampered =~ "response-content-disposition"
  end

  test "carries the file name through RFC 5987 encoding" do
    query = download_query(%{file_name: "quarterly report.pdf"})

    assert query["response-content-disposition"] ==
             "attachment; filename*=UTF-8''quarterly%20report.pdf"
  end

  test "strips path separators and control characters from the recorded name" do
    unsafe_name = "../../etc/pas\tswd" <> <<0>> <> ".txt"
    query = download_query(%{file_name: unsafe_name})

    disposition = query["response-content-disposition"]
    assert disposition =~ "attachment; filename*=UTF-8''"
    refute disposition =~ "/"
    refute disposition =~ <<0>>
  end

  test "falls back to a bare attachment disposition without a usable name" do
    assert download_query(%{file_name: nil})["response-content-disposition"] == "attachment"
    assert download_query(%{file_name: "   "})["response-content-disposition"] == "attachment"
  end

  test "issues a shorter lifetime than an upload URL" do
    assert {:ok, %{expires_in: download_ttl}} =
             CommsIntegrations.ObjectStorage.S3.presign_download(
               attachment(%{
                 object_key: "tenant/message.txt",
                 object_version_id: "version-1"
               })
             )

    assert {:ok, %{expires_in: upload_ttl}} =
             CommsIntegrations.ObjectStorage.S3.presign_upload(
               attachment(%{
                 object_key: "tenant/message.txt",
                 checksum_sha256: String.duplicate("a", 64)
               })
             )

    assert download_ttl == 120
    assert upload_ttl == 900
    assert download_ttl < upload_ttl
  end

  test "never exceeds the configured object-store lifetime" do
    Application.put_env(
      :comms_integrations,
      :s3,
      Application.get_env(:comms_integrations, :s3) |> Keyword.put(:expires_in, 90)
    )

    assert {:ok, %{expires_in: 90}} =
             CommsIntegrations.ObjectStorage.S3.presign_download(
               attachment(%{
                 object_key: "tenant/message.txt",
                 object_version_id: "version-1"
               })
             )
  end

  defp download_query(attrs) do
    assert {:ok, %{url: url}} =
             CommsIntegrations.ObjectStorage.S3.presign_download(
               attachment(
                 Map.merge(
                   %{object_key: "tenant/message.txt", object_version_id: "version-1"},
                   attrs
                 )
               )
             )

    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end
end
