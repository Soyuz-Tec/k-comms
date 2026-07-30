defmodule CommsIntegrations.ObjectStorage.S3.UploadVerifier do
  @moduledoc false

  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner}

  def verify_variant_upload(variant) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, key} <- ObjectMetadata.required_variant_key(variant),
         {:ok, checksum} <- ObjectMetadata.required_variant_checksum(variant),
         {:ok, expected_size} <- ObjectMetadata.required_variant_size(variant),
         {:ok, %{url: url, headers: request_headers}} <-
           Presigner.presign("HEAD", key, :internal, checksum_headers, []),
         request <- Finch.build(:head, url, Map.to_list(request_headers)),
         {:ok, %Finch.Response{status: status, headers: headers}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch),
         :ok <- ObjectMetadata.verify_size(headers, expected_size),
         :ok <- ObjectMetadata.verify_checksum(headers, checksum),
         :ok <- ObjectMetadata.verify_encryption(headers),
         {:ok, version} <- ObjectMetadata.response_version(headers) do
      {:ok, %{object_version_id: version}}
    else
      {:ok, %Finch.Response{status: 404}} -> {:error, :object_not_found}
      {:ok, %Finch.Response{status: status}} -> {:error, {:object_storage_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :object_verification_failed}
    end
  end

  def verify_upload(attachment) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, %{url: url, headers: request_headers}} <-
           Presigner.presign("HEAD", attachment.object_key, :internal, checksum_headers, []),
         request <- Finch.build(:head, url, Map.to_list(request_headers)),
         {:ok, %Finch.Response{status: status, headers: headers}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch),
         :ok <- ObjectMetadata.verify_size(headers, attachment.byte_size),
         {:ok, checksum} <- ObjectMetadata.required_checksum(attachment),
         :ok <- ObjectMetadata.verify_checksum(headers, checksum),
         :ok <- ObjectMetadata.verify_encryption(headers),
         {:ok, version} <- ObjectMetadata.response_version(headers),
         {:ok, etag} <- ObjectMetadata.response_etag(headers) do
      {:ok,
       %{
         object_version_id: version,
         object_etag: etag,
         verified_checksum_sha256: checksum
       }}
    else
      {:ok, %Finch.Response{status: 404}} -> {:error, :object_not_found}
      {:ok, %Finch.Response{status: status}} -> {:error, {:object_storage_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :object_verification_failed}
    end
  end
end
