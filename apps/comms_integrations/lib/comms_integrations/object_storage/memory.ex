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
       expires_in: 900,
       expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
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
         expires_in: 900,
         expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
       }}
    end
  end

  @impl true
  def presign_variant_upload(variant) do
    with {:ok, key} <- variant_key(variant) do
      {:ok,
       %{
         method: "PUT",
         url: url(key),
         approved_origin: approved_origin(),
         development_http: false,
         headers: %{"content-type" => value(variant, :content_type)},
         expires_in: 900,
         expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
       }}
    end
  end

  @impl true
  def presign_variant_download(variant) do
    with {:ok, key} <- variant_key(variant),
         {:ok, version} <- variant_version(variant) do
      {:ok,
       %{
         method: "GET",
         url: url(key) <> "?versionId=#{URI.encode_www_form(version)}",
         approved_origin: approved_origin(),
         development_http: false,
         headers: %{},
         expires_in: 900,
         expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
       }}
    end
  end

  @impl true
  def verify_variant_upload(variant) do
    with {:ok, _key} <- variant_key(variant) do
      {:ok, %{object_version_id: "memory-variant-v1"}}
    end
  end

  defp variant_key(variant) do
    case value(variant, :object_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :variant_object_key_unavailable}
    end
  end

  defp variant_version(variant) do
    case value(variant, :object_version_id) do
      version when is_binary(version) and version not in ["", "null"] -> {:ok, version}
      _ -> {:error, :variant_version_unavailable}
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
  def purge_object_versions(request) do
    with :ok <- CommsIntegrations.ObjectStorage.validate_object_request(request) do
      {:ok, %{deleted_versions: 0, deleted_markers: 0, verified_empty?: true}}
    end
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
