defmodule CommsIntegrations.Scanner.AllowAll do
  @behaviour CommsIntegrations.Scanner

  @impl true
  def scan(_request),
    do: {:ok, %{verdict: :clean, provider: "test_allow_all", provider_reference: nil}}

  @impl true
  def status, do: %{status: :available, adapter: "test_allow_all", test_only: true}
end
