defmodule CommsIntegrations.ObjectStorageTestSupport do
  @moduledoc false

  def attachment(attrs) do
    Map.merge(
      %{
        id: "attachment-test-id",
        tenant_id: "tenant",
        owner_user_id: "owner",
        file_name: "file.txt",
        content_type: "text/plain",
        byte_size: 1,
        status: :pending
      },
      attrs
    )
  end

  def upload(attachment, body) do
    with {:ok, descriptor} <- CommsIntegrations.ObjectStorage.S3.presign_upload(attachment),
         request <- Finch.build(:put, descriptor.url, Map.to_list(descriptor.headers), body),
         {:ok, %Finch.Response{status: status}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch) do
      :ok
    end
  end

  def s3_integration_config do
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

  def sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  def restore_env(key, nil), do: Application.delete_env(:comms_integrations, key)
  def restore_env(key, value), do: Application.put_env(:comms_integrations, key, value)
end
