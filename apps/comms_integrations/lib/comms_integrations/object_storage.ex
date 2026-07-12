defmodule CommsIntegrations.ObjectStorage do
  @callback presign_upload(map()) :: {:ok, map()} | {:error, term()}
  @callback presign_download(map()) :: {:ok, map()} | {:error, term()}
  @callback verify_upload(map()) :: {:ok, map()} | {:error, term()}
  @callback verify_restored_object(map()) :: {:ok, map()} | {:error, term()}
  @callback delete_object(map()) :: :ok | {:error, term()}
  @callback status() :: map()

  def presign_upload(request), do: adapter().presign_upload(request)
  def presign_download(request), do: adapter().presign_download(request)
  def verify_upload(request), do: adapter().verify_upload(request)

  def verify_restored_object(request) do
    with :ok <- validate_object_request(request) do
      adapter().verify_restored_object(request)
    end
  end

  def delete_object(request) do
    with :ok <- validate_object_request(request) do
      adapter().delete_object(request)
    end
  end

  def status, do: adapter().status()

  def validate_object_request(request) when is_map(request) do
    tenant_id = value(request, :tenant_id)
    object_key = value(request, :object_key)
    prefix = if is_binary(tenant_id), do: tenant_id <> "/", else: nil

    cond do
      not is_binary(tenant_id) or tenant_id == "" ->
        {:error, :invalid_object_tenant}

      not is_binary(object_key) or object_key == "" ->
        {:error, :invalid_object_key}

      not String.starts_with?(object_key, prefix) ->
        {:error, :object_tenant_mismatch}

      unsafe_object_key?(String.replace_prefix(object_key, prefix, "")) ->
        {:error, :invalid_object_key}

      true ->
        :ok
    end
  end

  def validate_object_request(_), do: {:error, :invalid_object_key}

  # Compatibility for callers built against the executable bootstrap API.
  def sign_upload(request), do: presign_upload(request)

  defp adapter do
    Application.get_env(
      :comms_integrations,
      :object_storage_adapter,
      CommsIntegrations.ObjectStorage.DenyAll
    )
  end

  defp unsafe_object_key?(relative) do
    relative == "" or String.contains?(relative, "\\") or
      String.match?(relative, ~r/[\x00-\x1F\x7F]/u) or
      relative
      |> String.split("/", trim: false)
      |> Enum.any?(&(&1 in ["", ".", ".."]))
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
