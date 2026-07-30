defmodule CommsIntegrations.ProviderSafetyTestSupport do
  @moduledoc false

  def destination(addresses \\ [{93, 184, 216, 34}]) do
    %{
      host: "hooks.example.test",
      port: 443,
      addresses: addresses,
      uri: URI.parse("https://hooks.example.test/events")
    }
  end

  def webhook_payload do
    %{
      "url" => "https://hooks.example.test/events",
      "secret" => "secret-value-with-enough-entropy",
      "body" => %{},
      "delivery_id" => "delivery-1",
      "event_type" => "message.created.v1",
      "idempotency_key" => "event-1-endpoint-1"
    }
  end

  def restore(key, nil), do: Application.delete_env(:comms_integrations, key)
  def restore(key, value), do: Application.put_env(:comms_integrations, key, value)
end

defmodule CommsIntegrations.ProviderSafetyTestSupport.PinnedTransport do
  @moduledoc false

  def request(destination, _method, _headers, _body, _opts) do
    [address | _] = destination.addresses
    send(self(), {:connected_address, address, destination.host, destination.uri.path})

    {:ok,
     %{
       status: Process.get(:pinned_status, 204),
       headers: [],
       body: ""
     }}
  end
end

defmodule CommsIntegrations.ProviderSafetyTestSupport.TransientTransport do
  @moduledoc false

  def request(_destination, _method, _headers, _body, _opts),
    do: {:error, Process.get(:provider_transport_error, :outbound_transport_error)}
end

defmodule CommsIntegrations.ProviderSafetyTestSupport.SlowDripMint do
  @moduledoc false

  def connect(:https, _address, _port, _opts) do
    Process.sleep(10)
    {:ok, %{}}
  end

  def request(conn, _method, _target, _headers, _body) do
    Process.sleep(10)
    {:ok, conn, :request}
  end

  def recv(conn, 0, timeout) do
    Process.sleep(min(timeout, 15))
    {:ok, conn, [{:data, :request, "x"}]}
  end

  def close(_conn), do: :ok
end

defmodule CommsIntegrations.ProviderSafetyTestSupport.FailingConnectMint do
  @moduledoc false

  def connect(:https, address, _port, opts) do
    timeout = opts |> Keyword.fetch!(:transport_opts) |> Keyword.fetch!(:timeout)
    send(self(), {:connect_timeout, address, timeout})
    Process.sleep(50)
    {:error, :closed}
  end
end

defmodule CommsIntegrations.ProviderSafetyTestSupport.AddressOutcomeMint do
  @moduledoc false

  def connect(:https, address, _port, opts) do
    timeout = opts |> Keyword.fetch!(:transport_opts) |> Keyword.fetch!(:timeout)
    send(self(), {:connect_attempt, address, timeout})

    case Process.get(:connect_outcomes, %{}) |> Map.get(address, :ok) do
      :ok ->
        {:ok, %{address: address}}

      :timeout ->
        Process.sleep(timeout)
        {:error, %Mint.TransportError{reason: :timeout}}

      {:tls, reason} ->
        {:error, %Mint.TransportError{reason: reason}}
    end
  end

  def request(conn, _method, _target, _headers, _body), do: {:ok, conn, :request}

  def recv(conn, 0, _timeout) do
    {:ok, conn, [{:status, :request, 204}, {:headers, :request, []}, {:done, :request}]}
  end

  def close(_conn), do: :ok
end

defmodule CommsIntegrations.ProviderSafetyTestSupport.ChunkedHeadersMint do
  @moduledoc false

  def connect(:https, _address, _port, _opts), do: {:ok, %{}}

  def request(conn, _method, _target, _headers, _body) do
    Process.put(:response_header_chunk_index, 0)
    {:ok, conn, :request}
  end

  def recv(conn, 0, _timeout) do
    chunks = Process.get(:response_header_chunks, [])
    index = Process.get(:response_header_chunk_index, 0)
    headers = Enum.fetch!(chunks, index)
    Process.put(:response_header_chunk_index, index + 1)
    send(self(), {:header_chunk, index})

    entries =
      if index == 0,
        do: [{:status, :request, 200}, {:headers, :request, headers}],
        else: [{:headers, :request, headers}]

    entries = if index == length(chunks) - 1, do: entries ++ [{:done, :request}], else: entries

    if Process.get(:response_header_recv_error, false),
      do: {:error, conn, :closed, entries},
      else: {:ok, conn, entries}
  end

  def close(_conn), do: :ok
end
