defmodule CommsCore.Administration.WorkspaceDomainsTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Administration, Audit, Repo}
  alias CommsCore.Accounts.{Session, User}

  alias CommsCore.Administration.{
    DomainUserErasureCommand,
    WorkspaceDomainClaim,
    WorkspaceDomains
  }

  alias CommsTestSupport.Fixtures
  @moduletag :integration

  defmodule Resolver do
    @behaviour CommsCore.Administration.DomainTXTResolver
    @impl true
    def lookup(query) do
      %{owner: owner, result: result} =
        Application.fetch_env!(:comms_core, :workspace_domain_test_dns)

      send(owner, {:domain_lookup, query})
      result
    end
  end

  setup do
    old = Application.get_env(:comms_core, :workspace_domain_txt_resolver)
    Application.put_env(:comms_core, :workspace_domain_txt_resolver, Resolver)

    on_exit(fn ->
      if old,
        do: Application.put_env(:comms_core, :workspace_domain_txt_resolver, old),
        else: Application.delete_env(:comms_core, :workspace_domain_txt_resolver)

      Application.delete_env(:comms_core, :workspace_domain_test_dns)
    end)

    :ok
  end

  test "an exact opt-in verified domain supplies only a trusted workspace sign-in hint" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    domain = unique_domain()
    assert {:ok, claim} = create(domain, subject, true)
    assert claim.status == :pending
    assert claim.version == 1
    assert Administration.discover_workspace_domain(domain).available == false

    dns({:ok, [claim.challenge_value]})

    assert {:ok, verified} =
             Administration.verify_workspace_domain(claim.id, %{version: 1}, subject)

    assert_receive {:domain_lookup, query}
    assert query.name == "_k-comms.#{domain}."
    assert query.timeout_ms in 1..5000
    assert verified.version == 2
    assert is_nil(verified.challenge_value)
    assert DateTime.diff(verified.proof_expires_at, verified.verified_at, :second) == 604_800

    view = Administration.discover_workspace_domain(String.upcase(domain) <> ".")

    assert Map.from_struct(view) == %{
             available: true,
             sign_in_path: "/sign-in?tenant_slug=#{account.tenant.slug}"
           }

    refute Map.has_key?(Map.from_struct(view), :tenant_id)
    refute Map.has_key?(Map.from_struct(view), :email)
    refute Administration.discover_workspace_domain("sub." <> domain).available

    assert length(
             Audit.list(%{tenant_id: account.tenant.id, action: "workspace_domain.verified"})
           ) == 1
  end

  test "unknown malformed opted-out expired and inactive domains share one neutral view" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    domain = unique_domain()
    assert {:ok, claim} = create(domain, subject)
    dns({:ok, [claim.challenge_value]})

    assert {:ok, verified} =
             Administration.verify_workspace_domain(claim.id, %{version: 1}, subject)

    neutral = Administration.discover_workspace_domain("missing.company.com")

    for input <- [
          domain,
          "person@#{domain}",
          "https://#{domain}",
          "*.#{domain}",
          "127.0.0.1",
          "company.local",
          " company.com",
          "éxample.com"
        ] do
      assert Administration.discover_workspace_domain(input) == neutral
    end

    assert {:ok, enabled} =
             Administration.update_workspace_domain_discovery(
               claim.id,
               %{version: 2, discovery_enabled: true},
               subject
             )

    assert Administration.discover_workspace_domain(domain).available

    timestamp = DateTime.add(DateTime.utc_now(), -1, :second)
    # Move both proof boundaries to preserve the real seven-day database check.
    Repo.update_all(from(c in WorkspaceDomainClaim, where: c.id == ^claim.id),
      set: [verified_at: DateTime.add(timestamp, -60, :second), proof_expires_at: timestamp]
    )

    assert Administration.discover_workspace_domain(domain) == neutral

    Repo.update_all(from(c in WorkspaceDomainClaim, where: c.id == ^claim.id),
      set: [verified_at: verified.verified_at, proof_expires_at: verified.proof_expires_at]
    )

    Repo.update_all(from(t in CommsCore.Administration.Tenant, where: t.id == ^account.tenant.id),
      set: [status: :suspended]
    )

    assert Administration.discover_workspace_domain(domain) == neutral
    assert enabled.version == 3
  end

  test "DNS failure wrong challenge and challenge expiry leave proof and audit unchanged" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, claim} = create(unique_domain(), subject, true)

    for {answer, error} <- [
          {{:error, :dns_unavailable}, :dns_unavailable},
          {{:error, :dns_timeout}, :dns_timeout},
          {{:ok, ["wrong-token"]}, :domain_proof_missing}
        ] do
      dns(answer)

      assert {:error, ^error} =
               Administration.verify_workspace_domain(claim.id, %{version: 1}, subject)

      assert Repo.get!(WorkspaceDomainClaim, claim.id).version == 1
      refute Administration.discover_workspace_domain(claim.domain).available

      assert Audit.count(%{tenant_id: account.tenant.id, action: "workspace_domain.verified"}) ==
               0
    end

    Repo.update_all(from(c in WorkspaceDomainClaim, where: c.id == ^claim.id),
      set: [challenge_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    dns({:ok, [claim.challenge_value]})

    assert {:error, :domain_challenge_expired} =
             Administration.verify_workspace_domain(claim.id, %{version: 1}, subject)

    assert Repo.get!(WorkspaceDomainClaim, claim.id).status == :pending
  end

  test "cross-tenant verified lease remains exclusive and only an expired lease can be replaced" do
    first = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    first_subject = Fixtures.step_up(first)
    other_subject = Fixtures.step_up(other)
    domain = unique_domain()
    assert {:ok, one} = create(domain, first_subject, true)
    dns({:ok, [one.challenge_value]})
    assert {:ok, _} = Administration.verify_workspace_domain(one.id, %{version: 1}, first_subject)
    assert {:ok, two} = create(domain, other_subject, true)
    dns({:ok, [two.challenge_value]})

    assert {:error, :domain_in_use} =
             Administration.verify_workspace_domain(two.id, %{version: 1}, other_subject)

    assert Administration.discover_workspace_domain(domain).sign_in_path ==
             "/sign-in?tenant_slug=#{first.tenant.slug}"

    timestamp = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(c in WorkspaceDomainClaim, where: c.id == ^one.id),
      set: [verified_at: DateTime.add(timestamp, -60, :second), proof_expires_at: timestamp]
    )

    assert {:ok, second_verified} =
             Administration.verify_workspace_domain(two.id, %{version: 1}, other_subject)

    assert second_verified.version == 2
    assert Repo.get!(WorkspaceDomainClaim, one.id).status == :expired
    assert Repo.get!(CommsCore.Administration.Tenant, first.tenant.id).status == :active

    assert Administration.discover_workspace_domain(domain).sign_in_path ==
             "/sign-in?tenant_slug=#{other.tenant.slug}"
  end

  test "version CAS rotation revocation and the exact eight-claim bound cannot be bypassed" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, first} = create(unique_domain(), subject)

    assert {:ok, rotated} =
             Administration.renew_workspace_domain(first.id, %{version: 1}, subject)

    refute rotated.challenge_value == first.challenge_value
    assert rotated.version == 2

    assert {:error, :stale_version} =
             Administration.verify_workspace_domain(first.id, %{version: 1}, subject)

    assert {:error, :version_required} =
             Administration.revoke_workspace_domain(first.id, %{}, subject)

    assert {:error, :invalid_workspace_domain} =
             Administration.update_workspace_domain_discovery(
               first.id,
               %{version: 2, discovery_enabled: true, email: "person@company.com"},
               subject
             )

    assert {:ok, _} = Administration.revoke_workspace_domain(first.id, %{version: 2}, subject)
    assert is_nil(Repo.get(WorkspaceDomainClaim, first.id))
    assert Audit.count(%{tenant_id: account.tenant.id, action: "workspace_domain.revoked"}) == 1

    for _ <- 1..8, do: assert({:ok, _} = create(unique_domain(), subject))
    assert {:error, :domain_limit_reached} = create(unique_domain(), subject)

    assert Repo.aggregate(
             from(c in WorkspaceDomainClaim, where: c.tenant_id == ^account.tenant.id),
             :count
           ) == 8
  end

  test "current proof and current identity reject cold revoked and limited administrators" do
    cold = Fixtures.account_fixture()
    assert {:error, :step_up_required} = create(unique_domain(), Fixtures.subject(cold))

    assert {:error, :step_up_required} =
             Administration.list_workspace_domains(Fixtures.subject(cold))

    revoked = Fixtures.account_fixture()
    subject = Fixtures.step_up(revoked)

    Repo.update_all(from(s in Session, where: s.id == ^revoked.session.id),
      set: [revoked_at: DateTime.utc_now()]
    )

    assert {:error, :forbidden} = create(unique_domain(), subject)

    limited = Fixtures.account_fixture()
    limited_subject = Fixtures.step_up(limited)

    for role <- [:owner, :admin, :moderator, :member, :security_admin, :compliance_admin] do
      Repo.update_all(from(u in User, where: u.id == ^limited.user.id),
        set: [role: role, access_scope: :conversation_only]
      )

      assert {:error, :forbidden} = create(unique_domain(), limited_subject)
    end

    refute Repo.exists?(WorkspaceDomainClaim)
  end

  test "governance removes personal challenges and detaches only renewable tenant proof state" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, pending} = create(unique_domain(), subject)
    assert {:ok, ready} = create(unique_domain(), subject, true)
    dns({:ok, [ready.challenge_value]})

    assert {:ok, verified} =
             Administration.verify_workspace_domain(ready.id, %{version: 1}, subject)

    assert {:ok, renewal} =
             Administration.renew_workspace_domain(ready.id, %{version: 2}, subject)

    command = %DomainUserErasureCommand{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      timestamp: DateTime.utc_now()
    }

    assert {:ok, {:ok, receipt}} =
             Repo.transaction(fn ->
               Administration.erase_workspace_domain_user_challenges(command)
             end)

    assert receipt.removed_challenges == 1
    assert receipt.detached_verified_leases == 1
    assert is_nil(Repo.get(WorkspaceDomainClaim, pending.id))
    retained = Repo.get!(WorkspaceDomainClaim, verified.id)
    assert retained.version == renewal.version + 1
    assert is_nil(retained.challenge_actor_user_id)
    assert is_nil(retained.challenge_token)
    assert retained.proof_expires_at == verified.proof_expires_at
    assert Administration.discover_workspace_domain(ready.domain).available
  end

  test "unavailable domain collaborators fail closed before persistence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    old = Application.fetch_env!(:comms_core, :workspace_domain_governance_adapter)
    Application.put_env(:comms_core, :workspace_domain_governance_adapter, nil)
    on_exit(fn -> Application.put_env(:comms_core, :workspace_domain_governance_adapter, old) end)
    assert {:error, :domain_governance_unavailable} = create(unique_domain(), subject)
    refute Repo.exists?(WorkspaceDomainClaim)
  end

  test "DNS names reject URLs wildcards IP literals suffix tricks and whitespace" do
    for input <- [
          "http://company.com",
          "company.com/path",
          "company.com:53",
          "*.company.com",
          "company..com",
          "company.com..",
          "127.0.0.1",
          "[::1]",
          "company.local",
          "company.com ",
          "会社.com",
          String.duplicate("x", 64) <> ".com"
        ] do
      assert {:error, :invalid_workspace_domain} = WorkspaceDomains.canonical_domain(input)
    end

    assert {:ok, "company.com"} = WorkspaceDomains.canonical_domain("COMPANY.COM.")
  end

  defp dns(result),
    do:
      Application.put_env(:comms_core, :workspace_domain_test_dns, %{
        owner: self(),
        result: result
      })

  defp unique_domain,
    do: "workspace-#{System.unique_integer([:positive, :monotonic])}.company.com"

  defp create(domain, subject, enabled \\ false),
    do:
      Administration.create_workspace_domain(
        %{domain: domain, version: 0, discovery_enabled: enabled},
        subject
      )
end
