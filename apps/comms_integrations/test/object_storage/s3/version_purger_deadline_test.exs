defmodule CommsIntegrations.ObjectStorage.S3.VersionPurgerDeadlineTest do
  use ExUnit.Case, async: false
  import CommsIntegrations.ObjectStorageTestSupport
  alias CommsIntegrations.ObjectStorage.S3.VersionPurger
  @key "tenant/exact.wav"

  setup do
    previous = Application.get_env(:comms_integrations, :s3)

    Application.put_env(:comms_integrations, :s3,
      scheme: "https",
      host: "objects.example.test",
      port: 443,
      bucket: "k-comms",
      region: "us-east-1",
      access_key_id: "synthetic-access",
      secret_access_key: "synthetic-secret",
      expires_in: 60
    )

    on_exit(fn -> restore_env(:s3, previous) end)
    :ok
  end

  test "an exhausted aggregate budget never starts a provider request" do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> [0, 60_001] end)

    requester = fn _, _, _ ->
      send(parent, :provider_invoked)
      {:ok, %{status: 200, body: listing([])}}
    end

    assert {:error, :object_storage_purge_timeout} =
             VersionPurger.purge_object_versions(request(), requester, sequence_clock(clock))

    refute_received :provider_invoked
  end

  test "partial deletion stops at the aggregate deadline and a retry re-lists exact remaining versions and markers" do
    parent = self()

    {:ok, provider} =
      Agent.start_link(fn ->
        %{
          time: 0,
          step: 20_000,
          entries: [{:version, "v1"}, {:version, "v2"}, {:delete_marker, "marker3"}]
        }
      end)

    clock = fn -> Agent.get(provider, & &1.time) end

    requester = fn http, max_bytes, options ->
      assert max_bytes == 262_144
      assert options[:pool_timeout] + options[:request_timeout] <= 30_000
      assert options[:receive_timeout] == options[:request_timeout]
      query = http.query |> URI.decode_query()
      method = http.method
      send(parent, {:provider_request, method, query})

      Agent.get_and_update(provider, fn state ->
        response =
          if method == "GET" do
            assert query["prefix"] == @key and query["max-keys"] == "100"
            %{status: 200, body: listing(state.entries)}
          else
            assert method == "DELETE"
            assert http.path == "/k-comms/tenant/exact.wav"
            assert query["versionId"] != "neighbor-version"
            %{status: 204, body: ""}
          end

        entries =
          if method == "DELETE",
            do: Enum.reject(state.entries, fn {_, id} -> id == query["versionId"] end),
            else: state.entries

        {{:ok, response}, %{state | time: state.time + state.step, entries: entries}}
      end)
    end

    assert {:error, :object_storage_purge_timeout} =
             VersionPurger.purge_object_versions(request(), requester, clock)

    assert_receive {:provider_request, "GET", _}
    assert_receive {:provider_request, "DELETE", %{"versionId" => "v1"}}
    assert_receive {:provider_request, "DELETE", %{"versionId" => "v2"}}
    refute_received {:provider_request, _, _}
    assert Agent.get(provider, & &1.entries) == [{:delete_marker, "marker3"}]

    Agent.update(provider, &%{&1 | step: 1_000})

    assert {:ok, %{verified_empty?: true, deleted_versions: 0, deleted_markers: 1}} =
             VersionPurger.purge_object_versions(request(), requester, clock)

    assert_receive {:provider_request, "GET", _}
    assert_receive {:provider_request, "DELETE", %{"versionId" => "marker3"}}
    assert_receive {:provider_request, "GET", _}
    refute_received {:provider_request, _, _}
  end

  test "an empty-listing response after expiry cannot attest verified empty" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    requester = fn _, _, _ ->
      Agent.update(clock, fn _ -> 60_000 end)
      {:ok, %{status: 200, body: listing([])}}
    end

    assert {:error, :object_storage_purge_timeout} =
             VersionPurger.purge_object_versions(request(), requester, fn ->
               Agent.get(clock, & &1)
             end)
  end

  test "a provider operation that ignores its HTTP timeout is cancelled before returning from the fenced purge" do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> [0, 59_800] end)

    requester = fn _, _, options ->
      assert options[:pool_timeout] + options[:request_timeout] <= 200
      send(parent, {:blocked_provider, self()})

      receive do
        :never_sent -> {:ok, %{status: 200, body: listing([])}}
      end
    end

    assert {:error, :object_storage_purge_timeout} =
             VersionPurger.purge_object_versions(request(), requester, sequence_clock(clock))

    assert_receive {:blocked_provider, pid}
    refute Process.alive?(pid)
  end

  defp sequence_clock(agent),
    do: fn ->
      Agent.get_and_update(agent, fn [current | rest] ->
        {current, if(rest == [], do: [current], else: rest)}
      end)
    end

  defp request(), do: %{tenant_id: "tenant", object_key: @key}

  defp listing(entries) do
    exact =
      Enum.map_join(entries, "", fn {kind, id} ->
        element = if kind == :delete_marker, do: "DeleteMarker", else: "Version"
        "<#{element}><Key>#{@key}</Key><VersionId>#{id}</VersionId></#{element}>"
      end)

    "<ListVersionsResult><IsTruncated>false</IsTruncated>" <>
      exact <>
      "<Version><Key>#{@key}.neighbor</Key><VersionId>neighbor-version</VersionId></Version></ListVersionsResult>"
  end
end
