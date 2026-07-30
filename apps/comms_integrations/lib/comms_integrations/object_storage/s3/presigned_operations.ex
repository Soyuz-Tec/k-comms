defmodule CommsIntegrations.ObjectStorage.S3.PresignedOperations do
  @moduledoc false

  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner}

  def presign_upload(attachment) do
    with {:ok, checksum} <- ObjectMetadata.required_checksum(attachment) do
      headers = %{
        "content-type" => attachment.content_type,
        "x-amz-checksum-sha256" => ObjectMetadata.checksum_base64(checksum),
        "x-amz-meta-sha256" => checksum,
        "x-amz-server-side-encryption" => ObjectMetadata.server_side_encryption()
      }

      Presigner.presign("PUT", attachment.object_key, :public, headers, [])
    end
  end

  def presign_download(attachment) do
    with {:ok, version} <- ObjectMetadata.required_version(attachment) do
      Presigner.presign(
        "GET",
        attachment.object_key,
        :public,
        %{},
        [{"versionId", version}] ++ download_response_overrides(attachment),
        :download
      )
    end
  end

  def presign_variant_upload(variant) do
    with {:ok, key} <- ObjectMetadata.required_variant_key(variant),
         {:ok, content_type} <- ObjectMetadata.required_variant_content_type(variant),
         {:ok, checksum} <- ObjectMetadata.required_variant_checksum(variant) do
      headers = %{
        "content-type" => content_type,
        "x-amz-checksum-sha256" => ObjectMetadata.checksum_base64(checksum),
        "x-amz-meta-sha256" => checksum,
        "x-amz-server-side-encryption" => ObjectMetadata.server_side_encryption()
      }

      Presigner.presign("PUT", key, :public, headers, [])
    end
  end

  def presign_variant_download(variant) do
    with {:ok, key} <- ObjectMetadata.required_variant_key(variant),
         {:ok, content_type} <- ObjectMetadata.required_variant_content_type(variant),
         {:ok, version} <- ObjectMetadata.required_variant_version(variant) do
      Presigner.presign(
        "GET",
        key,
        :public,
        %{},
        [
          {"versionId", version},
          {"response-content-type", content_type},
          {"response-content-disposition", "inline"}
        ],
        :download
      )
    end
  end

  defp download_response_overrides(attachment) do
    [
      {"response-content-type", "application/octet-stream"},
      {"response-content-disposition",
       content_disposition(ObjectMetadata.value(attachment, :file_name))}
    ]
  end

  defp content_disposition(file_name) when is_binary(file_name) do
    case sanitized_filename(file_name) do
      "" -> "attachment"
      safe -> "attachment; filename*=UTF-8''#{Presigner.encode(safe)}"
    end
  end

  defp content_disposition(_file_name), do: "attachment"

  defp sanitized_filename(file_name) do
    file_name
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
    |> String.replace(~r{[/\\]}, "_")
    |> String.trim()
    |> String.slice(0, 200)
  end
end
