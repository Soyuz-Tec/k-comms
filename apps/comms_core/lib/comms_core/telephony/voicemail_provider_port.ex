defmodule CommsCore.Telephony.VoicemailProviderPort do
  @moduledoc "Telephony-owned port for qualified PBX stored recordings."
  alias CommsCore.Telephony.VoicemailRequest
  @spec ready?() :: boolean()
  def ready?(), do: match?({:ok, _}, adapter())

  @spec fetch(VoicemailRequest.t()) ::
          {:ok, CommsCore.Telephony.VoicemailProviderPort.Contract.media()} | {:error, atom()}
  def fetch(%VoicemailRequest{} = request) do
    with true <- valid?(request),
         {:ok, adapter} <- adapter(),
         {:ok,
          %{
            body: body,
            content_type: "audio/wav",
            duration_seconds: seconds,
            recording_name: name
          } = media} <- adapter.fetch(request),
         true <-
           name == request.recording_name and is_binary(body) and byte_size(body) in 1..8_388_608 and
             is_integer(seconds) and seconds in 1..120 do
      {:ok, media}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_voicemail_media}
    end
  end

  @spec delete(VoicemailRequest.t()) :: :ok | {:error, atom()}
  def delete(%VoicemailRequest{} = request) do
    with true <- valid?(request), {:ok, adapter} <- adapter(false) do
      adapter.delete(request)
    else
      {:error, _} = error -> error
      _ -> {:error, :voicemail_provider_identity_invalid}
    end
  end

  defp valid?(r),
    do:
      match?({:ok, _}, Ecto.UUID.cast(r.tenant_id)) and
        match?({:ok, _}, Ecto.UUID.cast(r.call_id)) and
        r.recording_name == "kc_vm_" <> String.replace(r.call_id, "-", "")

  defp adapter(require_ready \\ true) do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :voicemail_provider_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <-
           Enum.all?([fetch: 1, delete: 1, ready?: 0], fn {name, arity} ->
             function_exported?(adapter, name, arity)
           end),
         true <- not require_ready or adapter.ready?() == true do
      {:ok, adapter}
    else
      _ -> {:error, :telephony_voicemail_unavailable}
    end
  end
end
