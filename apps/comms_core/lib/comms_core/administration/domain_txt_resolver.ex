defmodule CommsCore.Administration.DomainTXTResolver do
  @moduledoc """
  DNS TXT technical boundary; never follows HTTP destinations or evaluates email.

  Resolver answers and errors are bounded. A failed or uncertain lookup cannot
  verify a claim and cannot extend an existing proof lease.
  """
  alias CommsCore.Administration.{DomainNames, DomainTXTQuery}
  @callback lookup(DomainTXTQuery.t()) :: {:ok, [String.t()]} | {:error, atom()}

  @spec lookup(DomainTXTQuery.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def lookup(%DomainTXTQuery{name: name, timeout_ms: timeout} = query)
      when is_binary(name) and is_integer(timeout) and timeout in 1..5000 do
    adapter =
      Application.get_env(:comms_core, :workspace_domain_txt_resolver, __MODULE__.SystemDNS)

    if DomainNames.exact_challenge_name?(name) and is_atom(adapter) and
         Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :lookup, 1) do
      bounded_lookup(adapter, query)
    else
      {:error, :dns_unavailable}
    end
  end

  def lookup(_query), do: {:error, :dns_unavailable}

  defp bounded_lookup(adapter, query) do
    caller = self()
    reference = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(caller, {reference, adapter.lookup(query)}) end)

    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        validate_answer(result)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :dns_unavailable}
    after
      query.timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :dns_timeout}
    end
  end

  defp validate_answer({:ok, records}) when is_list(records) do
    if length(records) <= 64 and
         Enum.all?(records, &(is_binary(&1) and byte_size(&1) <= 4096)) and
         Enum.reduce(records, 0, &(byte_size(&1) + &2)) <= 65_536,
       do: {:ok, records},
       else: {:error, :dns_unavailable}
  end

  defp validate_answer({:error, reason}) when reason in [:dns_timeout, :dns_unavailable],
    do: {:error, reason}

  defp validate_answer(_answer), do: {:error, :dns_unavailable}

  defmodule SystemDNS do
    @moduledoc false
    @behaviour CommsCore.Administration.DomainTXTResolver
    alias CommsCore.Administration.DomainTXTQuery

    @impl true
    def lookup(%DomainTXTQuery{name: name, timeout_ms: timeout}) do
      case :inet_res.resolve(String.to_charlist(name), :in, :txt, [], timeout) do
        {:ok, response} ->
          # inet_dns helpers expose the answer section without coupling to the
          # Erlang record tuple layout. Only TXT RDATA is interpreted.
          answers = :inet_dns.msg(response, :anlist)

          records =
            for answer <- answers,
                :inet_dns.rr(answer, :type) == :txt,
                exact_name?(:inet_dns.rr(answer, :domain), name) do
              :inet_dns.rr(answer, :data) |> IO.iodata_to_binary()
            end

          {:ok, records}

        {:error, :nxdomain} ->
          {:ok, []}

        {:error, :timeout} ->
          {:error, :dns_timeout}

        _ ->
          {:error, :dns_unavailable}
      end
    end

    defp exact_name?(answer_name, requested_name) do
      answer_name
      |> List.to_string()
      |> String.downcase()
      |> String.trim_trailing(".") == String.trim_trailing(requested_name, ".")
    end
  end
end
