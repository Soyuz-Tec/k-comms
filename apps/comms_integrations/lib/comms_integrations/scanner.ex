defmodule CommsIntegrations.Scanner do
  @callback scan(map()) :: {:ok, map()} | {:error, term()}
  @callback status() :: map()

  def scan(request), do: adapter().scan(request)
  def status, do: adapter().status()

  defp adapter do
    Application.get_env(:comms_integrations, :scanner_adapter, CommsIntegrations.Scanner.DenyAll)
  end
end
