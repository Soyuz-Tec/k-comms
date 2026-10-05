defmodule CommsCore.Telephony.VoicemailStoragePort.Contract do
  @moduledoc "Telephony-owned approved storage adapter contract."
  alias CommsCore.Telephony.VoicemailObject

  @type playback :: %{
          url: String.t(),
          approved_origin: String.t(),
          development_http: boolean(),
          expires_at: DateTime.t(),
          expires_in: pos_integer(),
          content_type: String.t()
        }
  @callback ingest(VoicemailObject.t(), binary()) :: {:ok, VoicemailObject.t()} | {:error, atom()}
  @callback download(VoicemailObject.t()) :: {:ok, playback()} | {:error, atom()}
  @callback delete(VoicemailObject.t()) :: :ok | {:error, atom()}
  @callback ready?() :: boolean()
end
