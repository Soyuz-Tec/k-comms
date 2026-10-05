defmodule CommsCore.AudioCalls.ArtifactStoragePort do
  @moduledoc "Calls-owned port; playback and erasure use only approved version-pinned storage."
  alias CommsCore.AudioCalls.ArtifactStorageObject
  @spec verify(ArtifactStorageObject.t()) :: {:ok, ArtifactStorageObject.t()} | {:error, atom()}
  def verify(%ArtifactStorageObject{} = object) do
    with {:ok, adapter} <- adapter(),
         {:ok, %ArtifactStorageObject{} = verified} <- adapter.verify(object),
         true <-
           verified.tenant_id == object.tenant_id and verified.object_key == object.object_key,
         true <-
           verified.byte_size == object.byte_size and verified.content_type == object.content_type,
         true <-
           is_binary(verified.object_version_id) and
             verified.object_version_id not in ["", "null"],
         true <- is_binary(verified.object_etag) and verified.object_etag != "",
         true <-
           is_binary(verified.checksum_sha256) and
             Regex.match?(~r/^[a-f0-9]{64}$/, verified.checksum_sha256),
         true <- verified.verified_checksum_sha256 == verified.checksum_sha256 do
      {:ok, verified}
    else
      {:error, _} = error -> error
      _ -> {:error, :artifact_storage_identity_invalid}
    end
  end

  @spec download(ArtifactStorageObject.t()) ::
          {:ok, CommsCore.AudioCalls.ArtifactStoragePort.Contract.descriptor()} | {:error, atom()}
  def download(%ArtifactStorageObject{} = object) do
    with {:ok, adapter} <- adapter(), do: adapter.download(object)
  end

  @spec delete(ArtifactStorageObject.t()) :: :ok | {:error, atom()}
  def delete(%ArtifactStorageObject{} = object) do
    with {:ok, adapter} <- adapter(), do: adapter.delete(object)
  end

  defp adapter do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :artifact_storage_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <-
           Enum.all?([verify: 1, download: 1, delete: 1], fn {name, arity} ->
             function_exported?(adapter, name, arity)
           end) do
      {:ok, adapter}
    else
      _ -> {:error, :artifact_storage_unavailable}
    end
  end
end
