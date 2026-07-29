defmodule CommsIntegrations.ObjectStorage.S3.EndpointPolicy do
  @moduledoc false

  @local_development_hosts [
    "localhost",
    "127.0.0.1",
    "::1",
    "minio",
    "host.containers.internal"
  ]

  def status(config \\ Application.get_env(:comms_integrations, :s3, [])) do
    required = [:scheme, :host, :port, :bucket, :region, :access_key_id, :secret_access_key]
    missing = Enum.filter(required, &(Keyword.get(config, &1) in [nil, ""]))
    internal_scheme = Keyword.get(config, :internal_scheme, Keyword.get(config, :scheme))
    internal_host = Keyword.get(config, :internal_host, Keyword.get(config, :host))
    internal_port = Keyword.get(config, :internal_port, Keyword.get(config, :port))

    cond do
      missing != [] ->
        %{status: :unavailable, adapter: "s3", reason: :missing_configuration, missing: missing}

      not allowed?(
        Keyword.get(config, :scheme),
        Keyword.get(config, :host),
        Keyword.get(config, :port)
      ) ->
        %{status: :unavailable, adapter: "s3", reason: :insecure_public_object_storage_endpoint}

      not allowed?(internal_scheme, internal_host, internal_port) ->
        %{status: :unavailable, adapter: "s3", reason: :insecure_internal_object_storage_endpoint}

      true ->
        %{status: :available, adapter: "s3"}
    end
  end

  def validate(:internal, scheme, host, port) do
    if allowed?(scheme, host, port),
      do: :ok,
      else: {:error, :insecure_internal_object_storage_endpoint}
  end

  def validate(:public, scheme, host, port) do
    if allowed?(scheme, host, port),
      do: :ok,
      else: {:error, :insecure_public_object_storage_endpoint}
  end

  def allowed?("https", host, port),
    do: is_binary(host) and host != "" and is_integer(port) and port > 0

  def allowed?("http", host, port) do
    Application.get_env(:comms_integrations, :allow_insecure_local_object_storage, false) and
      local_development_host?(host) and is_integer(port) and port > 0
  end

  def allowed?(_, _, _), do: false

  defp local_development_host?(host) do
    host in @local_development_hosts or exact_insecure_local_host?(host)
  end

  defp exact_insecure_local_host?(host) when is_binary(host) do
    case Application.get_env(:comms_integrations, :insecure_local_object_storage_host) do
      selected when is_binary(selected) ->
        selected == host and canonical_rfc1918_ipv4?(selected)

      _other ->
        false
    end
  end

  defp exact_insecure_local_host?(_host), do: false

  defp canonical_rfc1918_ipv4?(value) do
    with {:ok, address} <- :inet.parse_ipv4_address(String.to_charlist(value)),
         true <- address |> :inet.ntoa() |> to_string() == value do
      case address do
        {10, _, _, _} -> true
        {172, second, _, _} when second in 16..31 -> true
        {192, 168, _, _} -> true
        _other -> false
      end
    else
      _invalid -> false
    end
  end
end
