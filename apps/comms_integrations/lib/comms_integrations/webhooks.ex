defmodule CommsIntegrations.Webhooks do
  @callback deliver(map()) :: :ok | {:ok, map()} | {:error, term()}
  @callback status() :: map()
  def deliver(request), do: adapter().deliver(request)
  def status, do: adapter().status()

  def validate_destination(url) do
    config = Application.get_env(:comms_integrations, :webhook_http, [])

    CommsIntegrations.HttpPolicy.validate_https_destination(
      url,
      Keyword.get(
        config,
        :allowed_hosts,
        Application.get_env(:comms_integrations, :webhook_allowed_hosts, [])
      ),
      Keyword.get(config, :allowed_ports, [443])
    )
  end

  def validate_configured_destination(url) do
    config = Application.get_env(:comms_integrations, :webhook_http, [])

    CommsIntegrations.HttpPolicy.validate_https_destination(
      url,
      Keyword.get(
        config,
        :allowed_hosts,
        Application.get_env(:comms_integrations, :webhook_allowed_hosts, [])
      ),
      Keyword.get(config, :allowed_ports, [443]),
      resolve: false
    )
  end

  defp adapter,
    do:
      Application.get_env(
        :comms_integrations,
        :webhook_adapter,
        CommsIntegrations.Webhooks.DenyAll
      )
end
