defmodule CommsCore.Telephony.VoicemailStoragePort do
  @moduledoc "Telephony-owned approved encrypted storage boundary."
  alias CommsCore.Telephony.VoicemailObject
  @spec ready?() :: boolean()
  def ready?(), do: match?({:ok, _}, adapter())
  @spec ingest(VoicemailObject.t(), binary()) :: {:ok, VoicemailObject.t()} | {:error, atom()}
  def ingest(%VoicemailObject{} = object, body)
      when is_binary(body) and byte_size(body) in 1..8_388_608 do
    checksum = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    expected = %{
      object
      | byte_size: byte_size(body),
        checksum_sha256: checksum,
        verified_checksum_sha256: nil
    }

    with true <- VoicemailObject.valid?(expected),
         {:ok, adapter} <- adapter(),
         {:ok, %VoicemailObject{} = stored} <- adapter.ingest(expected, body),
         true <-
           VoicemailObject.verified?(stored) and stored.tenant_id == expected.tenant_id and
             stored.voicemail_id == expected.voicemail_id and
             stored.object_key == expected.object_key and stored.byte_size == expected.byte_size and
             stored.checksum_sha256 == checksum do
      {:ok, stored}
    else
      {:error, _} = error -> error
      _ -> {:error, :voicemail_storage_identity_invalid}
    end
  end

  def ingest(_, _), do: {:error, :invalid_voicemail_media}

  @spec download(VoicemailObject.t()) ::
          {:ok, CommsCore.Telephony.VoicemailStoragePort.Contract.playback()} | {:error, atom()}
  def download(%VoicemailObject{} = object) do
    with true <- VoicemailObject.verified?(object), {:ok, adapter} <- adapter() do
      adapter.download(object)
    else
      {:error, _} = error -> error
      _ -> {:error, :voicemail_storage_identity_invalid}
    end
  end

  @spec delete(VoicemailObject.t()) :: :ok | {:error, atom()}
  def delete(%VoicemailObject{} = object) do
    with true <- VoicemailObject.valid?(object), {:ok, adapter} <- adapter(false) do
      adapter.delete(object)
    else
      {:error, _} = error -> error
      _ -> {:error, :voicemail_storage_identity_invalid}
    end
  end

  defp adapter(require_ready \\ true) do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :voicemail_storage_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <-
           Enum.all?([ingest: 2, download: 1, delete: 1, ready?: 0], fn {name, arity} ->
             function_exported?(adapter, name, arity)
           end),
         true <- not require_ready or adapter.ready?() == true do
      {:ok, adapter}
    else
      _ -> {:error, :telephony_voicemail_unavailable}
    end
  end
end
