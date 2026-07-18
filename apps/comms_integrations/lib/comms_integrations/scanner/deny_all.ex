defmodule CommsIntegrations.Scanner.DenyAll do
  @behaviour CommsIntegrations.Scanner

  @impl true
  def scan(_request), do: {:error, :scanner_not_configured}

  @impl true
  def status, do: %{status: :unavailable, adapter: "deny_all", reason: :scanner_not_configured}
end
