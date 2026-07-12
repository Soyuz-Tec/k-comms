defmodule CommsIntegrations.Scanner.Log do
  @behaviour CommsIntegrations.Scanner
  require Logger

  @impl true
  def scan(request) do
    Logger.warning("attachment scan withheld by development log adapter",
      tenant_id: value(request, :tenant_id),
      attachment_id: value(request, :attachment_id)
    )

    {:error, :scanner_log_adapter_has_no_verdict}
  end

  @impl true
  def status, do: %{status: :degraded, adapter: "log", reason: :no_malware_verdict}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
