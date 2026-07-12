defmodule CommsIntegrations.ObjectStorageTest do
  use ExUnit.Case, async: false

  alias CommsCore.Attachments.Attachment

  test "memory adapter returns bounded upload and download intents" do
    attachment = %Attachment{object_key: "tenant/file name.txt", content_type: "text/plain"}

    assert {:ok, %{method: "PUT", url: upload_url, expires_in: 900}} =
             CommsIntegrations.ObjectStorage.Memory.presign_upload(attachment)

    assert upload_url =~ "file%20name.txt"

    assert {:ok, %{method: "GET", url: download_url}} =
             CommsIntegrations.ObjectStorage.Memory.presign_download(attachment)

    assert download_url == upload_url
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
      object_key: "tenant/message.txt",
      content_type: "text/plain",
      checksum_sha256: checksum
    }

    assert {:ok, %{method: "PUT", url: url, expires_in: 600, headers: headers}} =
             CommsIntegrations.ObjectStorage.S3.presign_upload(attachment)

    assert url =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
    assert url =~ "X-Amz-Signature="
    refute url =~ "secret-key"

    assert headers == %{
             "content-type" => "text/plain",
             "x-amz-meta-sha256" => checksum
           }

    signed_headers = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert signed_headers["X-Amz-SignedHeaders"] ==
             "content-type;host;x-amz-meta-sha256"
  end

  defp restore_env(key, nil), do: Application.delete_env(:comms_integrations, key)
  defp restore_env(key, value), do: Application.put_env(:comms_integrations, key, value)
end
