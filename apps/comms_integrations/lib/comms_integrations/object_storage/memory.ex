defmodule CommsIntegrations.ObjectStorage.Memory do
  @behaviour CommsIntegrations.ObjectStorage

  @impl true
  def presign_upload(attachment) do
    {:ok,
     %{
       method: "PUT",
       url: url(attachment.object_key),
       approved_origin: approved_origin(),
       development_http: false,
       headers: %{"content-type" => attachment.content_type},
       expires_in: 900
     }}
  end

  @impl true
  def presign_download(attachment) do
    with {:ok, version} <- version(attachment) do
      {:ok,
       %{
         method: "GET",
         url: url(attachment.object_key) <> "?versionId=#{URI.encode_www_form(version)}",
         approved_origin: approved_origin(),
         development_http: false,
         headers: %{},
         expires_in: 900
       }}
    end
  end

  @impl true
  def verify_upload(attachment) do
    checksum = value(attachment, :checksum_sha256)

    if is_binary(checksum) and Regex.match?(~r/^[a-f0-9]{64}$/, checksum) do
      {:ok,
       %{
         object_version_id: "memory-v1-#{String.slice(checksum, 0, 16)}",
         object_etag: "\"#{checksum}\"",
         verified_checksum_sha256: checksum
       }}
    else
      {:error, :object_checksum_required}
    end
  end

  @impl true
  def verify_restored_object(_attachment),
    do: {:error, :restore_verification_not_supported}

  @impl true
  def delete_object(request) do
    with :ok <- CommsIntegrations.ObjectStorage.validate_object_request(request), do: :ok
  end

  @impl true
  def status, do: %{status: :available, adapter: "memory", test_only: true}

  defp url(object_key) do
    encoded = object_key |> String.split("/") |> Enum.map_join("/", &URI.encode/1)
    "https://object-storage.test/#{encoded}"
  end

  defp approved_origin, do: "https://object-storage.test"

  defp version(attachment) do
    case value(attachment, :object_version_id) do
      version when is_binary(version) and version != "" -> {:ok, version}
      _ -> {:error, :object_version_unavailable}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
