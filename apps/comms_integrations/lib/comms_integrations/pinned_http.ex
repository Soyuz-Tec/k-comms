defmodule CommsIntegrations.PinnedHttp do
  alias CommsIntegrations.HttpPolicy

  @default_timeout 10_000

  def request(method, url, headers, body, opts) when is_list(opts) do
    allowed_hosts = Keyword.get(opts, :allowed_hosts, [])
    allowed_ports = Keyword.get(opts, :allowed_ports, [443])
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    deadline = monotonic_ms() + timeout

    policy_opts =
      opts
      |> Keyword.take([:resolver])
      |> Keyword.put(:deadline_ms, deadline)

    with {:ok, destination} <-
           HttpPolicy.resolve_https_destination(url, allowed_hosts, allowed_ports, policy_opts),
         :ok <- before_deadline(deadline) do
      transport = Keyword.get(opts, :transport, __MODULE__.MintTransport)

      transport.request(
        destination,
        method,
        headers,
        body,
        Keyword.put(opts, :deadline_ms, deadline)
      )
    end
  end

  defp before_deadline(deadline) do
    if monotonic_ms() < deadline, do: :ok, else: {:error, :outbound_timeout}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
