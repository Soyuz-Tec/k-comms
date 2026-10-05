defmodule CommsCore.Administration.DomainTXTResolverTest do
  use ExUnit.Case, async: false
  alias CommsCore.Administration.{DomainTXTQuery, DomainTXTResolver}

  defmodule Resolver do
    @behaviour CommsCore.Administration.DomainTXTResolver
    @impl true
    def lookup(query) do
      %{owner: owner, result: result} =
        Application.fetch_env!(:comms_core, :workspace_domain_resolver_test)

      send(owner, {:technical_dns_entered, self(), query})

      case result do
        :wait ->
          receive do
            :release -> {:ok, ["late-result"]}
          end

        :crash ->
          raise "synthetic resolver failure"

        result ->
          result
      end
    end
  end

  setup do
    old = Application.get_env(:comms_core, :workspace_domain_txt_resolver)
    Application.put_env(:comms_core, :workspace_domain_txt_resolver, Resolver)

    on_exit(fn ->
      if old,
        do: Application.put_env(:comms_core, :workspace_domain_txt_resolver, old),
        else: Application.delete_env(:comms_core, :workspace_domain_txt_resolver)

      Application.delete_env(:comms_core, :workspace_domain_resolver_test)
    end)

    :ok
  end

  test "the DNS boundary rejects URLs unrelated labels and IP names before resolver work" do
    answer({:ok, []})

    for name <- [
          "https://company.com",
          "company.com.",
          "_k-comms.127.0.0.1.",
          "_k-comms.company.com..",
          "_k-comms.company.local.",
          "_k-comms.company.com",
          "_K-COMMS.company.com."
        ] do
      assert {:error, :dns_unavailable} =
               DomainTXTResolver.lookup(%DomainTXTQuery{name: name, timeout_ms: 100})
    end

    refute_receive {:technical_dns_entered, _, _}, 10
  end

  test "the bounded worker returns valid TXT records without inventing proof" do
    answer({:ok, ["unrelated=txt", "k-comms-workspace-verification=synthetic"]})
    assert {:ok, records} = DomainTXTResolver.lookup(query())
    assert records == ["unrelated=txt", "k-comms-workspace-verification=synthetic"]
    assert_receive {:technical_dns_entered, _, %{name: "_k-comms.company.com."}}
  end

  test "uncertain crashes malformed responses and oversized TXT answers fail closed" do
    for result <- [
          :crash,
          {:ok, [42]},
          {:ok, List.duplicate("txt", 65)},
          {:ok, [String.duplicate("x", 4097)]},
          {:ok, List.duplicate(String.duplicate("x", 4096), 17)},
          {:error, :unexpected},
          :invalid
        ] do
      answer(result)
      assert {:error, :dns_unavailable} = DomainTXTResolver.lookup(query())
    end
  end

  test "the wall-clock deadline kills a delayed DNS worker and returns no successful answer" do
    answer(:wait)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :dns_timeout} =
             DomainTXTResolver.lookup(%DomainTXTQuery{
               name: "_k-comms.company.com.",
               timeout_ms: 50
             })

    assert System.monotonic_time(:millisecond) - started_at < 1000
    assert_receive {:technical_dns_entered, pid, _query}
    reference = Process.monitor(pid)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 1000
    refute_receive {:ok, _late_answer}, 10
  end

  defp query, do: %DomainTXTQuery{name: "_k-comms.company.com.", timeout_ms: 1000}

  defp answer(result),
    do:
      Application.put_env(:comms_core, :workspace_domain_resolver_test, %{
        owner: self(),
        result: result
      })
end
