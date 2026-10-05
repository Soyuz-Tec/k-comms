defmodule CommsCore.Telephony.VoicemailProviderPort.Contract do
  @moduledoc "Telephony-owned stored-recording adapter contract."
  alias CommsCore.Telephony.VoicemailRequest

  @type media :: %{
          body: binary(),
          content_type: String.t(),
          duration_seconds: pos_integer(),
          recording_name: String.t()
        }
  @callback fetch(VoicemailRequest.t()) :: {:ok, media()} | {:error, atom()}
  @callback delete(VoicemailRequest.t()) :: :ok | {:error, atom()}
  @callback ready?() :: boolean()
end
