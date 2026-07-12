defmodule CommsIntegrations.RuntimeConfig do
  alias CommsIntegrations.HttpPolicy

  @notification_modes ~w(disabled http log)
  @scanner_modes ~w(disabled http allow_all log)
  @webhook_modes ~w(disabled http log)
  @host_pattern ~r/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/

  def validate!(options) when is_list(options) do
    development_adapters? = Keyword.fetch!(options, :development_adapters?)
    notification_mode = validate_mode!(options, :notification_mode, @notification_modes)
    scanner_mode = validate_mode!(options, :scanner_mode, @scanner_modes)
    webhook_mode = validate_mode!(options, :webhook_mode, @webhook_modes)

    require_development_gate!(notification_mode, ["log"], development_adapters?)
    require_development_gate!(scanner_mode, ["allow_all", "log"], development_adapters?)
    require_development_gate!(webhook_mode, ["log"], development_adapters?)

    notification_http = Keyword.fetch!(options, :notification_http)
    scanner_http = Keyword.fetch!(options, :scanner_http)
    webhook_http = Keyword.fetch!(options, :webhook_http)
    provider_preflight? = Keyword.get(options, :provider_preflight?, true)

    if provider_preflight? and notification_mode == "http" do
      validate_http_provider!(
        notification_http,
        "NOTIFICATION_PROVIDER",
        [:endpoint, :token, :provider_name]
      )
    end

    if provider_preflight? and scanner_mode == "http" do
      validate_http_provider!(
        scanner_http,
        "ATTACHMENT_SCANNER",
        [:endpoint, :token, :provider_name]
      )
    end

    if provider_preflight? and webhook_mode in ["http", "log"] do
      validate_allowed_hosts!(Keyword.get(webhook_http, :allowed_hosts), "WEBHOOK_ALLOWED_HOSTS")
      validate_timeout!(Keyword.get(webhook_http, :timeout_ms), "WEBHOOK_TIMEOUT_MS")
    end

    %{
      notification_adapter: notification_adapter(notification_mode),
      notification_delivery_status: notification_delivery_status(notification_mode),
      scanner_adapter: scanner_adapter(scanner_mode),
      webhook_adapter: webhook_adapter(webhook_mode)
    }
  end

  defp validate_mode!(options, key, allowed) do
    mode = Keyword.fetch!(options, key)

    if mode in allowed do
      mode
    else
      raise ArgumentError,
            "#{mode_environment(key)} must be one of: #{Enum.join(allowed, ", ")}"
    end
  end

  defp require_development_gate!(mode, development_modes, development_adapters?) do
    if mode in development_modes and not development_adapters? do
      raise ArgumentError,
            "ALLOW_DEVELOPMENT_ADAPTERS=true is required for development provider mode #{mode}"
    end
  end

  defp validate_http_provider!(config, prefix, required_keys) do
    Enum.each(required_keys, fn key ->
      unless configured_text?(Keyword.get(config, key)) do
        raise ArgumentError, "#{prefix}_#{environment_suffix(key)} is required in http mode"
      end
    end)

    hosts_environment = "#{prefix}_ALLOWED_HOSTS"
    allowed_hosts = Keyword.get(config, :allowed_hosts)
    validate_allowed_hosts!(allowed_hosts, hosts_environment)
    validate_timeout!(Keyword.get(config, :timeout_ms), "#{prefix}_TIMEOUT_MS")

    case HttpPolicy.validate_https_destination(
           Keyword.get(config, :endpoint),
           allowed_hosts,
           Keyword.get(config, :allowed_ports, [443]),
           resolve: false
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "#{prefix}_ENDPOINT is not an allowed HTTPS destination (#{reason})"
    end
  end

  defp validate_allowed_hosts!(hosts, environment_name) when is_list(hosts) and hosts != [] do
    unless Enum.all?(hosts, &valid_host?/1) do
      raise ArgumentError, "#{environment_name} must contain explicit DNS hostnames"
    end
  end

  defp validate_allowed_hosts!(_hosts, environment_name) do
    raise ArgumentError, "#{environment_name} must contain at least one DNS hostname"
  end

  defp validate_timeout!(timeout, _environment_name)
       when is_integer(timeout) and timeout >= 100 and timeout <= 120_000,
       do: :ok

  defp validate_timeout!(_timeout, environment_name) do
    raise ArgumentError, "#{environment_name} must be between 100 and 120000 milliseconds"
  end

  defp valid_host?(host) when is_binary(host) do
    normalized = host |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    normalized == host and Regex.match?(@host_pattern, normalized) and
      match?({:error, _}, :inet.parse_address(String.to_charlist(normalized)))
  end

  defp valid_host?(_host), do: false

  defp configured_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp notification_adapter("http"), do: CommsIntegrations.Notifications.Http
  defp notification_adapter("log"), do: CommsIntegrations.Notifications.Log
  defp notification_adapter("disabled"), do: CommsIntegrations.Notifications.DenyAll

  defp notification_delivery_status("http"), do: :available
  defp notification_delivery_status("log"), do: :degraded
  defp notification_delivery_status("disabled"), do: :unavailable

  defp scanner_adapter("http"), do: CommsIntegrations.Scanner.Http
  defp scanner_adapter("allow_all"), do: CommsIntegrations.Scanner.AllowAll
  defp scanner_adapter("log"), do: CommsIntegrations.Scanner.Log
  defp scanner_adapter("disabled"), do: CommsIntegrations.Scanner.DenyAll

  defp webhook_adapter("http"), do: CommsIntegrations.Webhooks.Http
  defp webhook_adapter("log"), do: CommsIntegrations.Webhooks.Log
  defp webhook_adapter("disabled"), do: CommsIntegrations.Webhooks.DenyAll

  defp mode_environment(:notification_mode), do: "NOTIFICATION_PROVIDER_MODE"
  defp mode_environment(:scanner_mode), do: "ATTACHMENT_SCANNER_MODE"
  defp mode_environment(:webhook_mode), do: "WEBHOOK_PROVIDER_MODE"

  defp environment_suffix(:endpoint), do: "ENDPOINT"
  defp environment_suffix(:token), do: "TOKEN"
  defp environment_suffix(:provider_name), do: "NAME"
end
