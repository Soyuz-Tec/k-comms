defmodule CommsIntegrations.Telephony.VoicemailARI do
  @moduledoc "Authenticated TLS reconciliation of pre-bound Asterisk stored recordings."
  @behaviour CommsCore.Telephony.VoicemailProviderPort.Contract
  alias CommsCore.Telephony.VoicemailRequest
  alias CommsIntegrations.Telephony.AsteriskARI
  @impl true
  def ready?(), do: get_in(AsteriskARI.capabilities(), [:voicemail, :supported]) == true
  @impl true
  def fetch(%VoicemailRequest{operation: :reconcile} = request),
    do: AsteriskARI.recording(request)

  @impl true
  def delete(%VoicemailRequest{} = request) do
    case AsteriskARI.recording(%{request | operation: :delete}) do
      :deleted -> :ok
      {:error, _} = error -> error
      _ -> {:error, :telephony_provider_unavailable}
    end
  end
end
