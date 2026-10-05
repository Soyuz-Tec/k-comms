defmodule CommsCore.Administration.WorkspaceDomainAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Administration, Audit, Repo}
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.{Tenant, WorkspaceDomainClaim}
  alias CommsCore.Governance.TenantLock
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  @moduletag :integration
  @moduletag :concurrency
  @password "domain-authority-race-fixture-password-1234"

  test "a committed session withdrawal during a real governance lock wait prevents every domain effect" do
    fixture = fixture()
    parent = self()
    {holder, holder_pid, blocker} = hold_governance(parent, fixture)
    creator = actor(parent, :creator, fn -> create(fixture) end)
    assert_receive {:creator_backend, backend}, 5_000
    assert_wait(backend, blocker)

    # Commit on an independent connection before the domain command reaches
    # the exact current identity parent locks. No authorization adapter is stubbed.
    unboxed(fn ->
      Repo.update_all(from(s in Session, where: s.id == ^fixture.account.session.id),
        set: [revoked_at: DateTime.utc_now()]
      )
    end)

    send(holder_pid, :release_governance)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:error, :forbidden} = Task.await(creator, 5_000)
    assert_no_effects(fixture)
  end

  test "session expiry reached during the governance fence wait cannot create a domain challenge" do
    fixture = fixture()
    expires_at = DateTime.add(DateTime.utc_now(), 3, :second)

    unboxed(fn ->
      Repo.update_all(from(s in Session, where: s.id == ^fixture.account.session.id),
        set: [expires_at: expires_at]
      )
    end)

    parent = self()
    {holder, holder_pid, blocker} = hold_governance(parent, fixture)
    creator = actor(parent, :creator, fn -> create(fixture) end)
    assert_receive {:creator_backend, backend}, 5_000
    assert_wait(backend, blocker)
    wait_until_expired(expires_at)
    send(holder_pid, :release_governance)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:error, :forbidden} = Task.await(creator, 5_000)
    assert_no_effects(fixture)
  end

  test "a current owner creates exactly once after the same actual governance wait is released" do
    fixture = fixture()
    parent = self()
    {holder, holder_pid, blocker} = hold_governance(parent, fixture)
    creator = actor(parent, :creator, fn -> create(fixture) end)
    assert_receive {:creator_backend, backend}, 5_000
    assert_wait(backend, blocker)
    send(holder_pid, :release_governance)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, claim} = Task.await(creator, 5_000)
    assert claim.version == 1

    unboxed(fn ->
      assert Repo.aggregate(
               from(c in WorkspaceDomainClaim, where: c.tenant_id == ^fixture.account.tenant.id),
               :count
             ) == 1

      assert Audit.count(%{
               tenant_id: fixture.account.tenant.id,
               action: "workspace_domain.created"
             }) == 1
    end)
  end

  defmodule DelayedResolver do
    @behaviour CommsCore.Administration.DomainTXTResolver
    @impl true
    def lookup(query) do
      %{owner: owner, value: value, expires_at: expires_at} =
        Application.fetch_env!(:comms_core, :workspace_domain_race_dns)

      send(owner, {:actual_dns_entered, query})
      wait_until(expires_at)
      {:ok, [value]}
    end

    defp wait_until(timestamp) do
      if DateTime.compare(DateTime.utc_now(), timestamp) != :gt do
        receive do
        after
          10 -> wait_until(timestamp)
        end
      end
    end
  end

  defmodule ConcurrentResolver do
    @behaviour CommsCore.Administration.DomainTXTResolver
    @impl true
    def lookup(_query),
      do: {:ok, Application.fetch_env!(:comms_core, :workspace_domain_race_tokens)}
  end

  test "two tenant verifications waiting on the exact domain fence produce one verified lease" do
    first = fixture()
    other = fixture()
    {:ok, one} = unboxed(fn -> create(first) end)

    {:ok, two} =
      unboxed(fn ->
        Administration.create_workspace_domain(
          %{domain: first.domain, version: 0, discovery_enabled: true},
          Fixtures.subject(other.account)
        )
      end)

    old = Application.get_env(:comms_core, :workspace_domain_txt_resolver)
    Application.put_env(:comms_core, :workspace_domain_txt_resolver, ConcurrentResolver)

    Application.put_env(:comms_core, :workspace_domain_race_tokens, [
      one.challenge_value,
      two.challenge_value
    ])

    on_exit(fn ->
      if old,
        do: Application.put_env(:comms_core, :workspace_domain_txt_resolver, old),
        else: Application.delete_env(:comms_core, :workspace_domain_txt_resolver)

      Application.delete_env(:comms_core, :workspace_domain_race_tokens)
    end)

    parent = self()

    holder =
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            "workspace-domain:" <> first.domain
          ])

          send(parent, {:domain_retained, self()})

          receive do
            :release_domain -> :ok
          after
            12_000 -> raise "exact workspace domain holder timed out"
          end
        end)
      end)

    assert_receive {:holder_backend, blocker}, 5_000
    assert_receive {:domain_retained, holder_pid}, 5_000

    first_writer =
      actor(parent, :first, fn ->
        Administration.verify_workspace_domain(
          one.id,
          %{version: one.version},
          Fixtures.subject(first.account)
        )
      end)

    other_writer =
      actor(parent, :other, fn ->
        Administration.verify_workspace_domain(
          two.id,
          %{version: two.version},
          Fixtures.subject(other.account)
        )
      end)

    assert_receive {:first_backend, first_backend}, 5_000
    assert_receive {:other_backend, other_backend}, 5_000
    assert_wait(first_backend, blocker)
    assert_wait(other_backend, blocker)
    send(holder_pid, :release_domain)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    results = [Task.await(first_writer, 5_000), Task.await(other_writer, 5_000)]
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :domain_in_use}, &1)) == 1

    unboxed(fn ->
      assert Repo.aggregate(
               from(c in WorkspaceDomainClaim,
                 where: c.domain == ^first.domain and c.status == :verified
               ),
               :count
             ) == 1

      audit_count =
        Audit.count(%{tenant_id: first.account.tenant.id, action: "workspace_domain.verified"}) +
          Audit.count(%{tenant_id: other.account.tenant.id, action: "workspace_domain.verified"})

      assert audit_count == 1
      assert Administration.discover_workspace_domain(first.domain).available
    end)
  end

  test "session expiry during real DNS work rolls back the matching proof and public route" do
    fixture = fixture()
    {:ok, claim} = unboxed(fn -> create(fixture) end)
    expires_at = DateTime.add(DateTime.utc_now(), 2, :second)

    unboxed(fn ->
      Repo.update_all(from(s in Session, where: s.id == ^fixture.account.session.id),
        set: [expires_at: expires_at]
      )
    end)

    old_resolver = Application.get_env(:comms_core, :workspace_domain_txt_resolver)
    Application.put_env(:comms_core, :workspace_domain_txt_resolver, DelayedResolver)

    Application.put_env(:comms_core, :workspace_domain_race_dns, %{
      owner: self(),
      value: claim.challenge_value,
      expires_at: expires_at
    })

    on_exit(fn ->
      if old_resolver,
        do: Application.put_env(:comms_core, :workspace_domain_txt_resolver, old_resolver),
        else: Application.delete_env(:comms_core, :workspace_domain_txt_resolver)

      Application.delete_env(:comms_core, :workspace_domain_race_dns)
    end)

    assert {:error, :forbidden} =
             unboxed(fn ->
               Administration.verify_workspace_domain(
                 claim.id,
                 %{version: claim.version},
                 Fixtures.subject(fixture.account)
               )
             end)

    assert_receive {:actual_dns_entered, query}, 1_000
    assert query.name == "_k-comms.#{fixture.domain}."

    unboxed(fn ->
      current = Repo.get!(WorkspaceDomainClaim, claim.id)
      assert current.version == claim.version
      assert current.status == :pending
      assert is_nil(current.proof_expires_at)
      refute Administration.discover_workspace_domain(fixture.domain).available

      assert Audit.count(%{
               tenant_id: fixture.account.tenant.id,
               action: "workspace_domain.verified"
             }) == 0
    end)
  end

  defp fixture do
    account =
      unboxed(fn ->
        account = Fixtures.account_fixture(%{password: @password})

        assert {:ok, _} =
                 Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(account))

        account
      end)

    # Register cleanup immediately after the tenant exists, before any later
    # assertion could leave a committed synthetic fixture behind.
    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(from(t in Tenant, where: t.id == ^account.tenant.id))
      end)
    end)

    %{account: account, domain: "race-#{account.user.id}.company.com"}
  end

  defp create(fixture),
    do:
      Administration.create_workspace_domain(
        %{domain: fixture.domain, version: 0, discovery_enabled: true},
        Fixtures.subject(fixture.account)
      )

  defp hold_governance(parent, fixture) do
    holder =
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          TenantLock.lock!(fixture.account.tenant.id)
          send(parent, {:governance_retained, self()})

          receive do
            :release_governance -> :ok
          after
            12_000 -> raise "domain governance lock holder timed out"
          end
        end)
      end)

    assert_receive {:holder_backend, backend}, 5_000
    assert_receive {:governance_retained, pid}, 5_000
    {holder, pid, backend}
  end

  defp actor(parent, label, operation) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp assert_wait(backend, blocker),
    do: assert_wait(backend, blocker, System.monotonic_time(:millisecond) + 5_000)

  defp assert_wait(backend, blocker, deadline) do
    result =
      unboxed(fn ->
        Repo.query!(
          "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
          [backend]
        ).rows
      end)

    case result do
      [[query, blockers]] ->
        assert String.contains?(query, "pg_advisory_xact_lock")
        assert blocker in blockers

      [] ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("domain writer did not reach the actual governance owner lock"),
          else:
            (
              Process.sleep(10)
              assert_wait(backend, blocker, deadline)
            )
    end
  end

  defp wait_until_expired(timestamp) do
    if DateTime.compare(DateTime.utc_now(), timestamp) != :gt do
      Process.sleep(10)
      wait_until_expired(timestamp)
    end
  end

  defp assert_no_effects(fixture) do
    unboxed(fn ->
      refute Repo.exists?(
               from(c in WorkspaceDomainClaim, where: c.tenant_id == ^fixture.account.tenant.id)
             )

      assert Audit.count(%{
               tenant_id: fixture.account.tenant.id,
               action: "workspace_domain.created"
             }) == 0
    end)
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
